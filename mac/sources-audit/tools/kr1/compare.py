#!/usr/bin/env python3
"""KR1 출처 점검 4단계: 피드(feeds.json)·앱 블록(app-<id>.json)·사이트 본문(site-<id>.json)을 맞대어 기사별 지표를 낸다.
쓰기: python3 -I compare.py <결과 폴더> [출처 id,…]  → <결과>/cmp-<id>.json, 화면에 요약
빠진 줄 = 사이트 본문 줄 가운데 우리 글에 없는 것, 섞인 줄 = 우리 블록 가운데 사이트 본문 영역에 없거나 군더더기 꼴인 것."""
import json, os, re, sys

JUNK = [("기자소개·연락처", r"[\w.+-]+@[\w-]+\.[\w.]+|기자\s*$|^[가-힣]{2,4}\s?(기자|특파원)\b.{0,30}$|기자 구독|기자페이지|구독하기"),
        ("저작권", r"ⓒ|©|무단\s?전재|재배포\s?금지|Copyright|All rights reserved"),
        ("관련기사", r"관련\s?기사|함께 (본|읽)|많이 본|추천 기사|인기 기사|이 시각|다른 기사|Related|More from"),
        ("구독·반응·공유 단추", r"구독|뉴스레터|앱 (다운|설치)|카카오톡|채널 추가|제보|좋아요|댓글|공유하기|SNS|네이버\s?(뉴스|채널)|구글\s?뉴스"),
        ("광고", r"^(AD|광고|Advertisement|Sponsored)$|광고$"),
        ("사진 출처만", r"^[\(\[]?(사진|그래픽|영상|자료)\s?[=:/]\s?\S{1,20}[\)\]]?$|^\[?(연합뉴스|뉴스1|뉴시스|게티이미지|AP|AFP|로이터)[^가-힣]{0,6}\]?$"),
        ("AI 고지", r"AI\s?(가|로)\s?(생성|작성|번역)|Powered by AI|AI 기술을 활용")]

UI = re.compile(r"^(구독|크게보기|기사를 읽어드립니다\.?|Unmute|Mute|\d{1,2}:\d{2}|닫기|공유|AD|광고|더보기|이전|다음|좋아요|화나요|슬퍼요|\d+)$")

AD = re.compile(r"큰일났다|충격!|해라!|꼭 찍어라|원인\s?밝혀|바로가기\s?>|\.\.!|터진다!")

def norm(s):
    return re.sub(r"[\s\"'“”‘’·…\.,\-–—]+", "", s or "")

def junk(s):
    return [k for k, p in JUNK if re.search(p, s)]

def load(p):
    return json.load(open(p)) if os.path.exists(p) else None

def article(app, site):
    blocks = app.get("blocks", []) if app else []
    hidden = set(app.get("hidden", [])) if app else set()
    shown = [(i, b) for i, b in enumerate(blocks) if i not in hidden]
    texts = [b.get("text") or "" for _, b in shown if b.get("text")]
    ours = norm("".join(texts))
    r = {"path": app["trace"]["path"] if app else "-", "ok": bool(app and app["ok"]), "sec": round(app["seconds"], 1) if app else None,
         "ourChars": len(ours), "siteChars": site.get("chars") if site else None,
         "ourP": sum(1 for _, b in shown if b["type"] == "p"), "ourImg": sum(1 for _, b in shown if b["type"] == "img"),
         "ourCap": sum(1 for _, b in shown if b["type"] == "cap"), "ourH": sum(1 for _, b in shown if b["type"] == "h"),
         "ourLi": sum(1 for _, b in shown if b["type"] == "li"), "ourQuote": sum(1 for _, b in shown if b["type"] == "quote"),
         "hiddenN": len(hidden), "hiddenImg": sum(1 for i in hidden if blocks[i]["type"] == "img"), "byline": (app or {}).get("cleanupByline") or (app or {}).get("byline"),
         "paywalledApp": (app or {}).get("paywalled"), "trace": (app or {}).get("trace")}
    if site and site.get("found"):
        sn = norm(" ".join(site["lines"]))
        # 사이트 본문 영역의 군더더기(구독 단추·크게보기·영상 재생 표시·기자 줄·저작권)를 뺀 글자 수로도 비교
        clean = [l for l in site["lines"] if not UI.search(l) and not (len(l) < 80 and junk(l))]
        r["siteClean"] = len(norm("".join(clean)))
        r["pct"] = round(100 * len(ours) / max(1, site["chars"]))
        r["pctClean"] = round(100 * len(ours) / max(1, r["siteClean"]))
        allours = norm("".join(b.get("text") or "" for b in blocks))
        r["missing"] = [l for l in site["lines"] if len(norm(l)) >= 12 and norm(l)[:25] not in allours]
        # 문단 덮기: 사이트 본문 줄 가운데 문단다운 것(40자 이상·광고/관련기사 꼴 아님)이 우리 글에 얼마나 들었나(글자 기준)
        core = [l for l in site["lines"] if len(l) >= 40 and not AD.search(l) and not junk(l[:80])]
        tot = sum(len(norm(l)) for l in core)
        r["coverage"] = round(100 * sum(len(norm(l)) for l in core if norm(l)[:25] in allours) / tot) if tot else None
        r["movedOut"] = [l[:80] for l in site["lines"] if len(norm(l)) >= 6 and norm(l)[:25] in allours and norm(l)[:25] not in ours]  # 읽기 창이 숨긴 줄(기자 줄 → 바이라인 등)
        r["mixed"] = []
        for i, b in shown:
            t = b.get("text") or ""
            if not t: continue
            j = junk(t) if len(t) < 80 else []  # 긴 문단 속 "구독" 같은 낱말은 군더더기가 아님
            outside = len(norm(t)) >= 8 and norm(t)[:25] not in sn
            if j or outside: r["mixed"].append({"i": i, "type": b["type"], "junk": j, "outside": outside, "text": t[:120]})
        r["siteJunk"] = [l[:100] for l in site["lines"] if len(l) < 80 and junk(l)]
        for k in ("pTags", "bigImgs", "caps", "heads", "lis", "quotes", "tables", "embeds", "more", "pages", "flags", "how", "og", "imgs"):
            r["site_" + k] = site.get(k)
    elif site:
        r["siteErr"] = site.get("error") or ("본문 영역 못 찾음 " + str(site.get("flags")))
    # 사진 순서·설명 짝: 우리 블록에서 img 뒤 cap 이 오는지
    seq = "".join({"img": "I", "cap": "C"}.get(b["type"], "") for _, b in shown)
    r["imgSeq"] = seq
    r["orphanCap"] = len(re.findall(r"(^|[^I])C", seq))
    return r

def main(d, only=None):
    feeds = load(f"{d}/feeds.json")
    for f in feeds:
        if only and f["id"] not in only: continue
        apps = load(f"{d}/app-{f['id']}.json") or []
        sites = load(f"{d}/site-{f['id']}.json") or []
        rows = []
        for p in f.get("picked", []):
            app = next((a for a in apps if a["link"] == p["link"]), None)
            site = next((s for s in sites if s["link"] == p["link"]), None)
            r = article(app, site); r["link"] = p["link"]
            r["feed"] = {"descLen": p["desc"]["len"], "descHtml": p["desc"]["html"], "content": p["content"]["len"] if p["content"] else None,
                         "images": [(i.get("tag"), i.get("w"), i.get("h")) for i in p["images"]], "cats": p["categories"], "author": p["hasAuthor"], "date": bool(p["date"])}
            r["appFeed"] = app.get("app") if app else None
            rows.append(r)
        json.dump(rows, open(f"{d}/cmp-{f['id']}.json", "w"), ensure_ascii=False, indent=1)
        print(f"== {f['id']}")
        for r in rows:
            print(f"  {r['path']:8} ok={r['ok']} {r['ourChars']}/{r['siteChars']}~{r.get('siteClean')} ({r.get('pct')}%/{r.get('pctClean')}% 덮기 {r.get('coverage')}%) img {r['ourImg']}/{r.get('site_bigImgs')} cap {r['ourCap']}/{len(r.get('site_caps') or [])} h {r['ourH']}/{len(r.get('site_heads') or [])} li {r['ourLi']}/{r.get('site_lis')} miss {len(r.get('missing', []))} mixed {len(r.get('mixed', []))} {r.get('siteErr', '')}")

if __name__ == "__main__":
    main(sys.argv[1], set(sys.argv[2].split(",")) if len(sys.argv) > 2 else None)
