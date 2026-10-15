#!/usr/bin/env python3
"""INTL2 비교: 앱이 얻은 블록(ReadSweep 덤프) ↔ 실제 사이트 본문 영역(site.cjs) ↔ 피드(feeds.py).
쓰는 법: python3 -I compare.py <작업폴더>   (feeds.json · sweep-intl2.json · site.json 을 읽어 digest.json 을 씀)
digest.json 은 검토용 짧은 발췌를 담으므로 저장소 밖(작업폴더)에만 둔다. md 에는 수치·종류만 옮긴다."""
import json, re, sys, statistics

W = sys.argv[1]
feeds = {f["id"]: f for f in json.load(open(f"{W}/feeds.json"))}
sweep = {r["target"]["link"]: r for r in json.load(open(f"{W}/sweep-intl2.json"))}
site = json.load(open(f"{W}/site.json"))

def norm(s):
    s = (s or "").lower().replace("’", "'").replace("“", '"').replace("”", '"')
    return re.sub(r"[^a-z0-9가-힣]+", " ", s).strip()

MIX = [
    ("뉴스레터·구독 권유", r"\b(sign up|newsletter|subscribe|subscription|inbox|free trial|support our journalism|become a member|donate)\b"),
    ("관련 기사·더 읽기", r"\b(related|read more|more from|recommended|you may also|most read|also read|read next|further reading|watch:|listen:|more on this story|see also)\b"),
    ("기자 소개", r"\b(is a (senior |staff |contributing )?(reporter|writer|editor|correspondent)|covers .{0,40} for|follow (him|her|them) on|reach (him|her|them) at|based in .{0,30}\.$)"),
    ("광고·후원", r"\b(advertisement|sponsored|partner content|paid post)\b"),
    ("댓글·공유", r"\b(comments?|share this|share on|facebook|whatsapp)\b"),
    ("사진 출처 줄", r"^(getty images|reuters|ap photo|afp|epa|pa media|image:|photograph:|credit:|illustration:)|(getty images|/ reuters|/ ap|\(ap\)|\(reuters\))\s*$"),
    ("저작권·바닥글", r"(©|copyright|all rights reserved|terms of use|privacy policy)"),
    ("날짜·바이라인 줄", r"^(updated|published|posted|by )|\b(minutes?|hours?) ago\b"),
    ("유료벽 문구", r"(to continue reading|already a subscriber|create a free account|subscribe to continue|log in)"),
]

def kind(text):
    t = text.lower()
    for k, rx in MIX:
        if re.search(rx, t): return k
    return "기타(영역 밖 글)"

def contains(hay, needle):
    n = norm(needle)
    if not n: return True
    probe = n[:80] if len(n) > 80 else n
    return probe in hay

out = {}
for link, s in site.items():
    sid = s.get("sourceId")
    r = sweep.get(link)
    d = {"source": sid, "link": link, "status": s.get("status"), "siteError": s.get("error"), "captcha": s.get("captcha"),
         "cookie": s.get("cookie"), "paywallEl": s.get("paywallEl"), "paywallText": s.get("paywallText"),
         "regionHasPaywall": s.get("regionHasPaywall"), "free": s.get("isAccessibleForFree"), "region": s.get("regionTag"),
         "jsonld": s.get("jsonldBodyChars"), "pageChars": s.get("pageChars")}
    fi = next((x for x in feeds[sid].get("picked", []) if x["link"] == link), None)
    if fi: d["feed"] = {k: fi[k] for k in ("summaryChars", "summaryHtml", "contentChars", "contentParas", "contentImgs", "hasAuthor", "categories", "images", "date")}
    sb = s.get("blocks") or []
    prose = [b for b in sb if not b["junk"] and b["tag"] in ("p", "h2", "h3", "h4", "li", "blockquote", "pre")]
    d["site"] = {k: s.get(k) for k in ("paras", "chars", "heads", "lis", "quotes", "tables", "caps", "imgs", "smallImgs", "figures", "video", "social", "iframes", "moreBtn", "pagination")}
    if r:
        d["app"] = {"ok": r["ok"], "path": r["trace"]["path"], "seconds": round(r["seconds"], 1), "reason": r.get("reason"),
                    "http": r["trace"].get("http"), "visible": r["trace"].get("visible"), "paywalled": r.get("paywalled"),
                    "cover": r.get("coverFrom"), "coverSize": r.get("coverSize"), "coverNote": r.get("coverNote"), "byline": bool(r.get("byline"))}
        blocks = r.get("dump") or []
        hidden = set(r.get("hidden") or [])
        shown = [b for i, b in enumerate(blocks) if i not in hidden]
        ours = [b for b in shown if b["type"] in ("p", "h", "li", "quote", "pre") and b.get("text")]
        d["app"].update(chars=sum(len(b["text"]) for b in ours), paras=sum(b["type"] == "p" for b in ours),
                        heads=sum(b["type"] == "h" for b in ours), lis=sum(b["type"] == "li" for b in ours),
                        quotes=sum(b["type"] == "quote" for b in ours), imgs=sum(b["type"] == "img" for b in shown),
                        caps=sum(b["type"] == "cap" for b in shown), hiddenN=len(hidden),
                        hiddenKinds=sorted({blocks[i]["type"] for i in hidden}))
        # 사진 설명 짝: 설명 앞이 사진이 아닌 것
        d["app"]["orphanCaps"] = sum(1 for i, b in enumerate(shown) if b["type"] == "cap" and (i == 0 or shown[i - 1]["type"] != "img"))
        ourHay = norm(" ".join(b.get("text") or "" for b in shown))
        regionHay = norm(" ".join(b["text"] for b in sb))
        cleanHay = norm(" ".join(b["text"] for b in prose))
        miss = [b for b in prose if len(b["text"]) >= 25 and not contains(ourHay, b["text"])]
        d["missing"] = {"n": len(miss), "chars": sum(len(b["text"]) for b in miss),
                        "tags": sorted({b["tag"] for b in miss}), "sample": [b["text"][:90] for b in miss[:6]]}
        mixed = []
        for b in ours:
            if len(b["text"]) < 3 or contains(cleanHay, b["text"]): continue
            inJunk = contains(regionHay, b["text"])
            mixed.append({"type": b["type"], "kind": kind(b["text"]), "inRegionJunk": inJunk, "len": len(b["text"]), "sample": b["text"][:90]})
        d["mixed"] = mixed
        sc = s.get("chars") or 0
        d["pct"] = round(d["app"]["chars"] * 100 / sc) if sc else None
        # 같은 글자 기준(사이트 본문에도 있는 것만 센 우리 글자 / 사이트 글자)
        good = sum(len(b["text"]) for b in ours if contains(cleanHay, b["text"]))
        d["coverPct"] = round(good * 100 / sc) if sc else None
    out[link] = d
json.dump(out, open(f"{W}/digest.json", "w"), ensure_ascii=False, indent=1)
print(len(out), "articles")
