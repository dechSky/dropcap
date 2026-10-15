#!/usr/bin/env python3
"""INTL2 출처 피드 점검: 피드가 주는 것(제목·요약·전문·사진·날짜·분야·기자·링크)을 재고 출처마다 기사 3건을 고른다.
쓰는 법: python3 -I feeds.py <목록.txt> <결과폴더>
 - 결과폴더/feeds.json  출처별 피드 관찰 + 고른 기사
 - 결과폴더/replay.json 앱 ReadSweep(DROPCAP_TEST_READSWEEP_REPLAY)용 기사 목록
요청은 출처마다 하나, 사이 1.5초."""
import json, re, sys, time, urllib.request, html
import xml.etree.ElementTree as ET
from email.utils import parsedate_to_datetime

UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
NS = {"media": "http://search.yahoo.com/mrss/", "content": "http://purl.org/rss/1.0/modules/content/",
      "dc": "http://purl.org/dc/elements/1.1/", "atom": "http://www.w3.org/2005/Atom"}

def text(el):
    return "".join(el.itertext()) if el is not None else ""

def plain(s):
    s = re.sub(r"<script.*?</script>|<style.*?</style>", " ", s or "", flags=re.S | re.I)
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", s))).strip()

def local(tag):
    return tag.split("}")[-1]

def item_info(it, atom):
    g = lambda path: it.find(path, NS)
    title = plain(text(g("atom:title") if atom else g("title")))
    if atom:
        l = next((x.get("href") for x in it.findall("atom:link", NS) if x.get("rel", "alternate") == "alternate"), "")
        summary = text(g("atom:summary")); content = text(g("atom:content"))
        date = text(g("atom:published")) or text(g("atom:updated"))
        author = text(g("atom:author/atom:name"))
        cats = [c.get("term") for c in it.findall("atom:category", NS)]
    else:
        l = text(g("link")).strip()
        summary = text(g("description")); content = text(g("content:encoded"))
        date = text(g("pubDate")) or text(g("dc:date"))
        author = text(g("dc:creator")) or text(g("author"))
        cats = [text(c) for c in it.findall("category")]
    imgs = []
    for tag in ("media:content", "media:thumbnail", ".//media:content", ".//media:thumbnail"):
        for m in it.findall(tag, NS):
            u = m.get("url")
            if u and (m.get("medium") in (None, "image") ) and not any(u == x["url"] for x in imgs):
                imgs.append({"url": u, "w": m.get("width"), "h": m.get("height"), "from": local(m.tag)})
    for e in it.findall("enclosure"):
        if (e.get("type") or "").startswith("image") and e.get("url"):
            imgs.append({"url": e.get("url"), "w": None, "h": None, "from": "enclosure"})
    body = content or summary
    for m in re.finditer(r"<img[^>]+src=[\"']([^\"']+)", body or ""):
        imgs.append({"url": html.unescape(m.group(1)), "w": None, "h": None, "from": "html"}); break
    return {
        "title": title, "link": l, "date": date.strip(),
        "summaryChars": len(plain(summary)), "summaryHtml": bool(re.search(r"<(p|a|img|br|div)\b", summary or "", re.I)),
        "contentChars": len(plain(content)), "contentParas": len(re.findall(r"<p\b", content or "", re.I)),
        "contentImgs": len(re.findall(r"<img\b", content or "", re.I)),
        "hasAuthor": bool(author.strip()), "categories": [c for c in cats if c][:6], "images": imgs[:3],
    }

def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/rss+xml, application/xml, */*"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.status, r.read()

def pick(items):
    """최신 10건에서 3건: 가장 최신 · 요약/전문이 가장 긴 것 · 가장 짧은 것(서로 다르게)."""
    pool = [x for x in items[:10] if x["link"].startswith("http")]
    if not pool: return []
    out = [pool[0]]
    size = lambda x: max(x["contentChars"], x["summaryChars"])
    for cand in (sorted(pool, key=size, reverse=True), sorted(pool, key=size)):
        for c in cand:
            if c not in out: out.append(c); break
    for c in pool:
        if len(out) >= 3: break
        if c not in out: out.append(c)
    return out[:3]

def main():
    lst, outdir = sys.argv[1], sys.argv[2]
    srcs = [l.rstrip("\n").split("\t") for l in open(lst, encoding="utf-8") if l.strip()]
    res, replay = [], []
    for sid, name, kind, on, pay, url in srcs:
        rec = {"id": sid, "name": name, "on": on != "-", "paywall": pay, "feed": url}
        try:
            st, data = fetch(url)
            root = ET.fromstring(data)
            atom = local(root.tag) == "feed"
            items = root.findall("atom:entry", NS) if atom else root.findall("./channel/item")
            infos = [item_info(i, atom) for i in items]
            def dt(x):
                try: return parsedate_to_datetime(x["date"]).timestamp()
                except Exception:
                    try:
                        from datetime import datetime
                        return datetime.fromisoformat(x["date"].replace("Z", "+00:00")).timestamp()
                    except Exception: return 0
            infos.sort(key=dt, reverse=True)
            rec.update(http=st, format="atom" if atom else "rss", count=len(infos), items=infos[:10], picked=pick(infos))
            for p in rec["picked"]:
                replay.append({"target": {"sourceId": sid, "sourceName": name, "region": "intl", "title": p["title"],
                                          "link": p["link"], "image": p["images"][0]["url"] if p["images"] else None}})
        except Exception as e:
            rec["error"] = str(e)[:200]
        res.append(rec)
        print(sid, rec.get("count"), rec.get("error", ""), flush=True)
        time.sleep(1.5)
    json.dump(res, open(f"{outdir}/feeds.json", "w"), ensure_ascii=False, indent=1)
    json.dump(replay, open(f"{outdir}/replay.json", "w"), ensure_ascii=False, indent=1)

if __name__ == "__main__":
    main()
