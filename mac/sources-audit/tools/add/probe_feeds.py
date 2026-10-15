#!/usr/bin/env python3
"""출처 추가 1단계: 후보 피드 주소가 살아 있는지·최근 글이 나오는지 잰다.
쓰기: python3 -I probe_feeds.py <후보.tsv(id<TAB>url)> <결과.json>   요청 사이 1.5초."""
import json, re, sys, time, urllib.request, urllib.error, urllib.parse, xml.etree.ElementTree as ET
from email.utils import parsedate_to_datetime
from datetime import datetime, timezone

UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Dropcap/1.0"

def get(url, hops=4):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/rss+xml, application/atom+xml, application/xml, text/xml, text/html;q=0.8"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, r.geturl(), r.read(3_000_000)
    except urllib.error.HTTPError as e:
        if e.code in (307, 308) and hops and e.headers.get("Location"):
            return get(urllib.parse.urljoin(url, e.headers["Location"]), hops - 1)
        return e.code, url, b""

def when(s):
    s = (s or "").strip()
    if not s: return None
    try: return parsedate_to_datetime(s)
    except Exception: pass
    try: return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except Exception: return None

def scan(data):
    root = ET.fromstring(data)
    tag = root.tag.split('}')[-1]
    rows = []
    for el in root.iter():
        t = el.tag.split('}')[-1]
        if t in ("item", "entry", "url"):
            d = {c.tag.split('}')[-1]: (c.text or c.get("href") or "") for c in el}
            link = d.get("link") or d.get("loc") or ""
            dt = when(d.get("pubDate") or d.get("date") or d.get("published") or d.get("updated") or d.get("lastmod") or d.get("publication_date"))
            for c in el.iter():
                if c.tag.split('}')[-1] in ("publication_date",) and not dt: dt = when(c.text)
            enc = d.get("encoded") or d.get("content") or ""
            rows.append({"link": link.strip(), "date": dt.isoformat() if dt else None,
                         "title": (d.get("title") or "").strip()[:60], "full": len(re.sub(r"<[^>]+>", "", enc)) > 800})
    return tag, rows

out = {}
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line or line.startswith("#"): continue
    sid, url = line.split("\t")[:2]
    try:
        st, final, data = get(url)
        r = {"url": url, "status": st, "final": final, "bytes": len(data)}
        if data:
            try:
                tag, rows = scan(data)
                dates = sorted([x["date"] for x in rows if x["date"]], reverse=True)
                now = datetime.now(timezone.utc)
                newest = dates[0] if dates else None
                r.update(root=tag, items=len(rows), newest=newest,
                         ageHours=round((now - datetime.fromisoformat(newest)).total_seconds() / 3600, 1) if newest and datetime.fromisoformat(newest).tzinfo else None,
                         fullText=sum(x["full"] for x in rows), sample=[x["link"] for x in rows[:15]])
            except ET.ParseError as e:
                r.update(root="parse-error", head=data[:120].decode("utf-8", "replace"))
    except Exception as e:
        r = {"url": url, "error": repr(e)[:160]}
    out[sid] = r
    print(sid, r.get("status"), r.get("root"), r.get("items"), r.get("ageHours"), r.get("error", ""), flush=True)
    time.sleep(1.5)
json.dump(out, open(sys.argv[2], "w"), ensure_ascii=False, indent=1)
