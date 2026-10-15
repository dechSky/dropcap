#!/usr/bin/env python3
"""피드 원문을 한 번 받아 '피드로 넘어오는 것'을 숫자로 적는다(본문 글은 남기지 않음).

python3 -I feedinfo.py <srcaudit-KR2.txt> <출력.json>
- 출처마다 피드 1회, 요청 사이 1.5초.
- 기사마다: 제목 길이, 요약 길이·HTML 여부, content:encoded 길이, 사진(어디서·크기 속성), 날짜 꼴, 분야, 기자 칸 유무, 링크 꼴.
"""
import json, re, sys, time, urllib.error, urllib.parse, urllib.request
import xml.etree.ElementTree as ET

UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
NS = {
    "content": "http://purl.org/rss/1.0/modules/content/",
    "dc": "http://purl.org/dc/elements/1.1/",
    "media": "http://search.yahoo.com/mrss/",
    "atom": "http://www.w3.org/2005/Atom",
}
TAG = re.compile(r"<[^>]+>")


def text(el):
    return "" if el is None else ("".join(el.itertext()) if len(el) else (el.text or ""))


def plain(s):
    return re.sub(r"\s+", " ", TAG.sub(" ", s or "")).strip()


def item_info(it, atom):
    g = lambda q: it.find(q, NS)
    title = text(g("atom:title" if atom else "title"))
    desc = text(g("atom:summary" if atom else "description"))
    enc = text(g("content:encoded")) or (text(g("atom:content")) if atom else "")
    link = ""
    if atom:
        l = g("atom:link")
        link = l.get("href", "") if l is not None else ""
    else:
        link = text(g("link")).strip()
    imgs = []
    for m in it.findall("media:content", NS) + it.findall("media:thumbnail", NS):
        imgs.append({"from": m.tag.split("}")[1], "w": m.get("width"), "h": m.get("height")})
    for e in it.findall("enclosure"):
        if (e.get("type") or "").startswith("image"):
            imgs.append({"from": "enclosure", "len": e.get("length")})
    inline = re.findall(r"<img\b", desc + enc, re.I)
    if inline:
        imgs.append({"from": "html-img", "n": len(inline)})
    date = text(g("pubDate")) or text(g("dc:date")) or text(g("atom:updated")) or text(g("atom:published"))
    cats = [text(c).strip() for c in it.findall("category")] + [c.get("term", "") for c in it.findall("atom:category", NS)]
    author = text(g("author")) or text(g("dc:creator")) or text(g("atom:author"))
    return {
        "title_len": len(plain(title)),
        "desc_len": len(plain(desc)),
        "desc_html": bool(re.search(r"<(p|br|img|a|div|figure)\b", desc, re.I)),
        "encoded_len": len(plain(enc)),
        "images": imgs,
        "date": date.strip()[:40],
        "categories": [c for c in cats if c][:4],
        "has_author": bool(author.strip()),
        "link": link,
    }


def fetch(url, info, hops=3):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            info["http"] = r.status
            info["ctype"] = r.headers.get("Content-Type", "")
            return r.read(8_000_000)
    except urllib.error.HTTPError as e:  # 파이썬 3.9 는 308 을 따라가지 않는다
        if e.code in (301, 302, 307, 308) and hops and e.headers.get("Location"):
            info.setdefault("redirects", []).append(e.code)
            return fetch(urllib.parse.urljoin(url, e.headers["Location"]), info, hops - 1)
        raise


def main(listfile, out):
    rows = [l.rstrip("\n").split("\t") for l in open(listfile, encoding="utf-8") if l.strip()]
    res = {}
    for sid, name, kind, on, pay, url in rows:
        info = {"id": sid, "name": name, "url": url}
        try:
            raw = fetch(url, info)
            try:
                root = ET.fromstring(raw)
            except ET.ParseError as e:  # 앱 풀이기는 너그럽다: 맨 & 를 고쳐 다시
                info["xml_error"] = str(e)[:120]
                root = ET.fromstring(re.sub(rb"&(?!#?\w+;)", b"&amp;", raw))
            atom = root.tag.endswith("feed")
            items = root.findall("atom:entry", NS) if atom else root.findall("./channel/item")
            info["format"] = "atom" if atom else "rss"
            info["count"] = len(items)
            info["items"] = [item_info(i, atom) for i in items[:15]]
        except Exception as e:  # 받기·풀기 실패도 그대로 남긴다
            info["error"] = f"{type(e).__name__}: {e}"[:200]
        res[sid] = info
        print(sid, info.get("count", info.get("error")), file=sys.stderr)
        time.sleep(1.5)
    json.dump(res, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
