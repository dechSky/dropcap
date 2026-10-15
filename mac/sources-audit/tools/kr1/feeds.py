#!/usr/bin/env python3
"""KR1 출처 점검 1단계: 피드를 받아 넘어오는 것(제목·요약·사진·날짜·분야·기자·링크)을 재고, 출처마다 기사 3건을 고른다.
쓰기: python3 -I feeds.py <목록.txt> <결과 폴더>   → <결과>/feeds.json
요청 사이 1.5초. 본문은 저장하지 않고 길이·꼴만 남긴다(요약 앞 80자는 꼴 확인용으로 결과 폴더에만)."""
import json, re, sys, time, urllib.request, urllib.error, urllib.parse, xml.etree.ElementTree as ET
from html import unescape

UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
NS = {"content": "http://purl.org/rss/1.0/modules/content/", "dc": "http://purl.org/dc/elements/1.1/",
      "media": "http://search.yahoo.com/mrss/", "atom": "http://www.w3.org/2005/Atom"}
TAG = re.compile(r"<[^>]+>")

def get(url, hops=3):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/rss+xml,application/xml,*/*"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:  # 308 은 urllib 가 따라가지 않는다(앱의 URLSession 은 따라감)
        if e.code in (307, 308) and hops and e.headers.get("Location"):
            return get(urllib.parse.urljoin(url, e.headers["Location"]), hops - 1)
        raise

def text(el):
    return (el.text or "") if el is not None else ""

def describe(raw):
    plain = re.sub(r"\s+", " ", unescape(TAG.sub(" ", unescape(raw)))).strip()
    return {"len": len(plain), "html": bool(re.search(r"<(p|br|img|div|a)\b", unescape(raw), re.I)),
            "imgs": len(re.findall(r"<img\b", unescape(raw), re.I)), "head": plain[:80]}

def items(data):
    root = ET.fromstring(data)
    out = []
    for it in root.iter("item"):
        desc = text(it.find("description"))
        enc = text(it.find("content:encoded", NS))
        imgs = []
        for m in it.findall("media:content", NS) + it.findall("media:thumbnail", NS) + it.findall("enclosure"):
            u = m.get("url")
            if u: imgs.append({"url": u, "w": m.get("width"), "h": m.get("height"), "tag": m.tag.split('}')[-1]})
        for u in re.findall(r"<img[^>]+src=[\"']([^\"']+)", unescape(desc + enc)):
            imgs.append({"url": u, "tag": "img-in-html"})
        cats = [c.text for c in it.findall("category") if c.text]
        author = text(it.find("author")) or text(it.find("dc:creator", NS))
        out.append({"title": unescape(text(it.find("title"))).strip(), "link": text(it.find("link")).strip(),
                    "date": text(it.find("pubDate")) or text(it.find("dc:date", NS)),
                    "desc": describe(desc), "content": describe(enc) if enc else None,
                    "images": imgs[:4], "categories": cats[:5], "hasAuthor": bool(author.strip())})
    return out

PHOTO = re.compile(r"포토|사진|화보|\[영상\]|그래픽")
SHORT = re.compile(r"속보|1보|단신|인사|부고|날씨|\[표\]|게시판")

def pick(its):
    """최신 15건 가운데: 가장 최근 1 · 사진/짧은 기사로 보이는 것 1 · 요약이 가장 긴 것 1(긴 기사 후보)."""
    pool = [i for i in its[:15] if i["link"]]
    chosen = []
    def add(x):
        if x and x not in chosen: chosen.append(x)
    add(pool[0] if pool else None)
    add(next((i for i in pool if PHOTO.search(i["title"])), None))
    add(next((i for i in pool if SHORT.search(i["title"])), None))
    for i in sorted(pool, key=lambda i: -((i["content"] or i["desc"])["len"])):
        if len(chosen) >= 3: break
        add(i)
    return chosen[:3]

def main(lst, outdir, only=None):
    res = []
    for line in open(lst, encoding="utf-8"):
        f = line.rstrip("\n").split("\t")
        if len(f) < 6: continue
        sid, name, kind, on, pay, url = f[:6]
        if only and sid not in only: continue
        row = {"id": sid, "name": name, "kind": kind, "defaultOn": on == "기본켜짐", "paywall": None if pay == "-" else pay, "feed": url}
        try:
            st, data = get(url)
            its = items(data)
            row.update(status=st, count=len(its), sample=its[:15], picked=pick(its))
        except Exception as e:
            row.update(error=f"{type(e).__name__}: {e}")
        print(sid, row.get("count"), row.get("error", ""), flush=True)
        res.append(row)
        time.sleep(1.5)
    path = f"{outdir}/feeds.json"
    if only:  # 일부만 다시 받았으면 앞 결과에 덮어 넣는다
        old = {r["id"]: r for r in json.load(open(path))}
        old.update({r["id"]: r for r in res})
        res = [old[k] for k in old]
    json.dump(res, open(path, "w"), ensure_ascii=False, indent=1)

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], set(sys.argv[3].split(",")) if len(sys.argv) > 3 else None)
