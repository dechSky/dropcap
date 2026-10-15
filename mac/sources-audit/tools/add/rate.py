#!/usr/bin/env python3
"""출처마다 하루 글 수를 어림한다(피드·사이트맵 한 번 받기, 요청 사이 1.5초). 쓰기: python3 -I rate.py <candidates.json>"""
import json, re, sys, time, urllib.request
from datetime import datetime, timezone, timedelta
from email.utils import parsedate_to_datetime
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Dropcap/1.0"
def when(s):
    s = s.strip()
    for f in (parsedate_to_datetime, lambda x: datetime.fromisoformat(x.replace("Z", "+00:00")), lambda x: datetime.strptime(x[:19], "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone(timedelta(hours=9)))):
        try:
            d = f(s); return d if d.tzinfo else d.replace(tzinfo=timezone(timedelta(hours=9)))
        except Exception: pass
for c in json.load(open(sys.argv[1], encoding="utf-8")):
    try:
        t = urllib.request.urlopen(urllib.request.Request(c["url"], headers={"User-Agent": UA}), timeout=25).read().decode("utf-8", "replace")
    except Exception as e:
        print(c["id"], "ERR", e); continue
    if c["type"] == "sitemap":
        urls = re.findall(r"<url>(.*?)</url>", t, re.S)
        if c.get("match"): urls = [u for u in urls if re.search(c["match"], re.sub(r"<!\[CDATA\[|\]\]>", "", (re.search(r"<loc>(.*?)</loc>", u, re.S) or [None, ""])[1]).strip())]
        ds = [when(m) for u in urls for m in re.findall(r"<(?:lastmod|news:publication_date)>([^<]+)", u)[:1]]
    else:
        ds = [when(m) for m in re.findall(r"<(?:pubDate|dc:date|published|updated)>([^<]+)<", t)]
    ds = sorted([d for d in ds if d], reverse=True)
    now = datetime.now(timezone.utc)
    day = sum(1 for d in ds if now - d < timedelta(hours=24))
    span = (ds[0] - ds[-1]).total_seconds() / 3600 if len(ds) > 1 else None
    est = round(len(ds) / span * 24) if span else None
    print(c["id"].ljust(18), "kB", len(t) // 1024, "items", len(ds), "24h", day, "span_h", round(span, 1) if span else None, "per_day≈", est, flush=True)
    time.sleep(1.5)
