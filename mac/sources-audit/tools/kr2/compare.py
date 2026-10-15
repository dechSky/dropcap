#!/usr/bin/env python3
"""앱이 추린 블록(ReadSweep 덤프)과 헤드리스로 잰 사이트 본문을 맞대어 기사마다 숫자로 남긴다.

python3 -I compare.py <sweep-kr2.json> <site.json> <feedinfo.json> <출력 compare.json>
- 출력에는 숫자와 종류 이름만 넣는다(본문 글·기자 이름 없음) — 저장소에 옮겨도 되는 꼴.
"""
import json, re, sys

# 섞여 들어온 블록 종류(위에서부터 먼저 걸리는 것)
JUNK = [
    ("저작권 줄", re.compile(r"저작권|무단\s?전재|Copyright|ⓒ|Ⓒ|\(c\)|All rights reserved|재배포", re.I)),
    ("제보 안내", re.compile(r"제보는|제보하기|^제보$|카카오톡\s?okjebo")),
    ("기자 이메일·바이라인", re.compile(r"^[\w.+-]+@[\w-]+\.[\w.]+$|기자\s*[\w.+-]+@|^\(?.{0,20}기자\)?$|특파원\s*[\w.+-]+@|선임기자")),
    ("반응·공유 단추", re.compile(r"^(좋아요|슬퍼요|화나요|훈훈해요|추천해요|공유하기|URL이 복사되었습니다\.?|기사 스크랩|댓글|북마크|뉴스 듣기|프린트|이 기사를 추천합니다\.?|본문 글자 크기 조정)(\s*\d+개)?$|글자 크기")),
    ("관련·인기 기사", re.compile(r"지금 뜨는 뉴스|많이 본 뉴스|관련\s?기사|함께 보면|추천 기사|이 시각|인기 기사|주요 뉴스")),
    ("회원 전용 안내", re.compile(r"회원전용|회원 전용|로그인 해주시고|무료 회원가입")),
    ("AI 요약·해설 상자", re.compile(r"AI 요약|AI 해설|핵심요약|AI 기사요약|Key Points")),
    ("구독·홍보", re.compile(r"^.{0,60}(구독|뉴스레터|무료 체험|앱 설치|이벤트 응모)|매경플러스|한경 프리미엄|에디터 픽")),
    ("오디오·플레이어 안내", re.compile(r"browser does not support|audio element|재생|듣기 서비스")),
    ("입력·수정 날짜 줄", re.compile(r"^(입력|수정|발행일|업데이트)\s*[:：]?\s*\d{4}[.\-]")),
    ("방송 대본 표시", re.compile(r"^<?(앵커|기자|리포트)>?$|^\((영상취재|영상편집|촬영)\s*[:：]")),
]
JUNK_IMG = [
    ("기자 얼굴 사진", re.compile(r"/reporter/|/byline/|/journalist/|profile", re.I)),
    ("홍보 배너 그림", re.compile(r"promotion|/banner", re.I)),
    ("아이콘·공유 그림", re.compile(r"\.svg($|\?)|/icon|/btn_|share\.|logo", re.I)),
]

REAL_EMBED = re.compile(r"youtube|youtu\.be|twitter|twitter-tweet|x\.com|instagram|facebook|tiktok|tv\.naver|kakao|vimeo|VIDEO|dailymotion|player", re.I)
SENT_END = re.compile(r"(다|요|죠|음|함|됨|까)\s*[.!?]?[\"”’')\]]*$|[.!?。][\"”’')\]]*$")
AD_LINE = re.compile(r"로또|당첨|!\s*[\"”']?\s*$|\.\.\s*[\"”']?$|\?!|바로가기")  # 본문 상자 안 네이티브 광고 제목
norm = lambda s: re.sub(r"[\s​\xa0]+", "", s or "")


# 읽기 창이 보여 줄 때 이미 빼는 블록(ReaderView.hiddenBlocks · BodyCleanup.analyze 와 같은 규칙) — 표에는 '읽기 창에 남는 것'만 센다
BYLINE = re.compile(r"^\s*(?:\[[^\]]{1,20}\]\s*)?([가-힣]{2,4})\s?(기자|특파원|에디터|선임기자|객원기자|논설위원)(?:\s*[=·,]?\s*[\w.+-]+@[\w-]+(?:\.[\w-]+)+)?(?:\s*Powered by [\w .]{1,40})?\s*$")
ORPHAN_CAP = re.compile(r"^\s*[\(\[]?\s*(?:AI\s?생성\s?(?:영상|이미지|사진)|(?:사진|영상|이미지|그래픽|자료)\s?(?:=|제공|출처|:)[^.。]{0,30})\s*[\)\]]?\s*$")
IMG_JUNK = re.compile(r"(default[-_]?user|avatar|profile|reporter|byline|author|gravatar|/logo|logo[-_.]|favicon|/icons?/|icon[-_.]|spacer|blank\.|1x1|pixel\.|badge|sprite|emoji|/ads?/)")


def shown(blocks):
    hide = set()
    for i, b in enumerate(blocks):
        if b["type"] == "p":
            t = b.get("original") or b.get("text") or ""
            nxt = i + 1 < len(blocks) and blocks[i + 1]["type"] == "img"
            if BYLINE.search(t) or (not nxt and len(t) <= 40 and ORPHAN_CAP.search(t)):
                hide.add(i)
        if b["type"] == "img" and IMG_JUNK.search((b.get("src") or "").lower().split("?")[0]):
            hide.add(i)
    for i in list(hide):
        if i + 1 < len(blocks) and blocks[i]["type"] == "img" and blocks[i + 1]["type"] == "cap":
            hide.add(i + 1)
    return [b for i, b in enumerate(blocks) if i not in hide], len(hide)


def junk_kind(b):
    if b["type"] == "img":
        for k, rx in JUNK_IMG:
            if rx.search(b.get("src") or ""):
                return k
        return None
    t = (b.get("text") or "").strip()
    for k, rx in JUNK:
        if rx.search(t):
            return k
    return None


def compare(row, site):
    raw = (row.get("article") or {}).get("blocks") or []
    blocks, hidden = shown(raw)
    texts = [b for b in blocks if b.get("text")]
    ours = norm("".join(b["text"] for b in texts))
    r = {
        "link": row["target"]["link"], "sid": row["target"]["sourceId"], "title_len": len(row["target"]["title"]),
        "ok": row["ok"], "path": row["trace"]["path"], "sec": round(row["seconds"], 1),
        "ours_chars": len(ours), "ours_blocks": len(texts),
        "ours_img": sum(b["type"] == "img" for b in blocks), "ours_cap": sum(b["type"] == "cap" for b in blocks),
        "ours_h": sum(b["type"] == "h" for b in blocks), "ours_li": sum(b["type"] == "li" for b in blocks),
        "ours_quote": sum(b["type"] == "quote" for b in blocks),
        "byline": bool((row.get("article") or {}).get("byline")),
        "cover": row.get("coverFrom"), "cover_size": row.get("coverSize"), "cover_note": row.get("coverNote"),
        "paywalled": row.get("paywalled"), "hidden_by_reader": hidden,
        "raw_reporter_img": sum(b["type"] == "img" and "/reporter/" in (b.get("src") or "") for b in raw),
    }
    # 섞인 것: 종류 규칙에 걸린 블록(사이트 본문 상자 안이든 밖이든 읽기에는 군더더기)
    mixed = {}
    for b in blocks:
        k = junk_kind(b)
        if k:
            mixed[k] = mixed.get(k, 0) + 1
    # 캡션 없이 이어지는 '사진 설명 같은 p'(사진 바로 뒤 p 가 사이트에서는 캡션) — 사진 설명 짝 확인
    cap_as_p = 0
    for a, b in zip(blocks, blocks[1:]):
        if a["type"] == "img" and b["type"] == "p" and site and b.get("text") and any(
                norm(b["text"])[:20] and norm(b["text"])[:20] in norm(c) for c in site.get("capsText", [])):
            cap_as_p += 1
    r["cap_as_p"] = cap_as_p
    if site and not site.get("error") and site.get("how") == "density" and site.get("chars", 0) < 150:
        site = {**site, "error": "본문 상자를 못 찾음(글 거의 없는 페이지: 영상·만화·속보)"}
    if not site or site.get("error") or site.get("how") in (None, "none"):
        r["site"] = {"error": (site or {}).get("error") or "본문 영역 못 찾음", "http": (site or {}).get("http")}
        r["mixed"] = mixed
        return r
    # 문단으로 셀 줄: 20자 넘고 문장으로 끝나는 줄(본문 상자 안 광고 제목·다른 기사 제목·꼬리표는 문장 끝맺음이 없다)
    lines = [l for l in site["text"] if len(norm(l)) >= 20 and SENT_END.search(l.strip()) and not AD_LINE.search(l)]
    site_all = norm("".join(site["text"]))
    missing = [l for l in lines if norm(l)[:25] not in ours]
    # 사이트 본문 상자에도 없는 우리 블록(상자 밖에서 끌려온 것)
    outside = [b for b in texts if len(norm(b["text"])) >= 8 and norm(b["text"])[:25] not in site_all]
    for b in outside:
        if not junk_kind(b):
            mixed["본문 상자 밖 글(기타)"] = mixed.get("본문 상자 밖 글(기타)", 0) + 1
    site_chars = site["chars"]
    big_imgs = [i for i in site["imgs"] if (i["dw"] or 0) >= 150 or (i["w"] or 0) >= 300]
    r["site"] = {
        "http": site.get("http"), "how": site["how"], "chars": site_chars, "lines": site["lines"],
        "imgs": len(big_imgs), "small_imgs": len(site["imgs"]) - len(big_imgs), "caps": site["caps"],
        "heads": site["heads"], "quotes": site["quotes"], "lists": site["lists"], "tables": site["tables"],
        "embeds": [e for e in site["embeds"] if REAL_EMBED.search(e)], "ad_frames": sum(not REAL_EMBED.search(e) for e in site["embeds"]),
        "more": site["more"],
        "page": {**site["page"], "captcha": site["page"].get("captcha") and site_chars < 200},
    }
    r["pct"] = round(100 * len(ours) / site_chars) if site_chars else None
    r["coverage"] = round(100 * (len(lines) - len(missing)) / len(lines)) if lines else None
    r["missing_lines"] = len(missing)
    r["missing_chars"] = sum(len(norm(l)) for l in missing)
    r["missing_kinds"] = sorted({("사진 설명" if any(norm(l)[:20] in norm(c) for c in site.get("capsText", [])) else
                                  "목록·표" if False else "문단") for l in missing})
    r["outside_blocks"] = len(outside)
    r["outside_chars"] = sum(len(norm(b["text"])) for b in outside)
    r["mixed"] = mixed
    return r


def main(sweep, sitef, feedf, out):
    rows = json.load(open(sweep, encoding="utf-8"))
    site = json.load(open(sitef, encoding="utf-8"))
    feed = json.load(open(feedf, encoding="utf-8"))
    res = [compare(r, site.get(r["target"]["link"])) for r in rows]
    # 피드 쪽 숫자(기사 단위로 맞추지 않고 출처 단위 요약)
    fsum = {}
    for sid, f in feed.items():
        its = f.get("items") or []
        if not its:
            fsum[sid] = {"error": f.get("error"), "count": f.get("count", 0)}
            continue
        med = lambda xs: sorted(xs)[len(xs) // 2] if xs else 0
        fsum[sid] = {
            "count": f.get("count"), "format": f.get("format"), "redirects": f.get("redirects"), "xml_error": bool(f.get("xml_error")),
            "desc_med": med([i["desc_len"] for i in its]), "desc_max": max(i["desc_len"] for i in its),
            "desc_html": sum(i["desc_html"] for i in its), "encoded_med": med([i["encoded_len"] for i in its]),
            "img_from": sorted({im["from"] for i in its for im in i["images"]}),
            "img_wh": sorted({f'{im.get("w")}x{im.get("h")}' for i in its for im in i["images"] if im.get("w")})[:3],
            "img_items": sum(bool(i["images"]) for i in its), "n": len(its),
            "date": its[0]["date"], "cats": sum(bool(i["categories"]) for i in its), "author": sum(i["has_author"] for i in its),
            "link_sample": re.sub(r"\d{4,}", "<번호>", its[0]["link"])[:90],
        }
    json.dump({"articles": res, "feeds": fsum}, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main(*sys.argv[1:5])
