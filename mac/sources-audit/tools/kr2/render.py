#!/usr/bin/env python3
"""compare.json(숫자) + notes.json(사람이 본 메모)으로 mac/sources-audit/<id>.md 와 _KR2.md 를 쓴다.

python3 -I render.py <srcaudit-KR2.txt> <compare.json> <notes.json> <mac/sources-audit 폴더>
"""
import json, statistics, sys
from collections import Counter

RULE = {  # 섞임 종류 → 제안 처리
    "저작권 줄": "끝의 저작권 줄(무단 전재·Copyright) 빼기 — 공통 꼬리 정리 규칙",
    "제보 안내": "'제보는 카카오톡…' 꼬리 빼기",
    "기자 이메일·바이라인": "끝의 '이름 기자 메일' 줄을 본문에서 빼고 바이라인 칸으로(이미 byline 이 있으면 지우기만)",
    "반응·공유 단추": "반응 단추(좋아요·슬퍼요…)·공유·글자 크기·뉴스 듣기 목록 빼기 — 단추 영역 선택자 제외",
    "관련·인기 기사": "'지금 뜨는 뉴스'·관련 기사 목록 빼기 — 본문 뒤 목록 상자 제외",
    "구독·홍보": "구독·자사 유료 상품 홍보 목록 빼기",
    "오디오·플레이어 안내": "기사 듣기 플레이어의 대체 글('Your browser does not support…') 빼기 — <audio> 안 글 무시",
    "입력·수정 날짜 줄": "'입력/수정/발행일' 날짜 줄을 본문에서 빼기(날짜는 피드 값)",
    "방송 대본 표시": "방송 대본 꼬리표(<앵커>·영상취재)는 두되 회색 작은 글로 — 선택(빼지 않아도 됨)",
    "기자 얼굴 사진": "기자 얼굴 사진(/reporter/ 주소) 빼기 — 본문 첫 그림으로 크게 나옴",
    "아이콘·공유 그림": "공유 아이콘(svg) 그림 빼기",
    "홍보 배너 그림": "홍보 배너 그림 빼기(isJunk 에 promotion·banner)",
    "본문 상자 밖 글(기타)": "본문 상자 밖에서 끌려온 글 — 본문 영역 선택자 지정",
}


TAIL = ("저작권 줄", "기자 이메일·바이라인", "제보 안내", "방송 대본 표시")


def med(xs):
    xs = [x for x in xs if x is not None]
    return round(statistics.median(xs)) if xs else None


def verdict(arts, note):
    if note.get("verdict"):
        return note["verdict"]
    if not arts or not any(a["ok"] for a in arts):
        return "나쁨"
    cov = med([a.get("coverage") for a in arts])
    junk = sum(sum(v for k, v in a["mixed"].items() if k not in ("저작권 줄", "기자 이메일·바이라인", "방송 대본 표시")) for a in arts)
    if cov is not None and cov < 70:
        return "나쁨"
    if (cov is not None and cov < 90) or junk >= 3:
        return "부분"
    return "좋음"


def esc(s):
    return str(s).replace("|", "/").replace("\n", " ")


def art_row(a, n):
    s = a.get("site", {})
    if s.get("error"):
        site = f"사이트 못 잼({s.get('http') or ''} {s['error'][:40]})"
        pct = f"{a['ours_chars']} / ?"
    else:
        pct = f"{a['ours_chars']} / {s['chars']} ({a.get('pct')}%) · 문단 대조 {a.get('coverage')}%"
    miss = "없음" if not a.get("missing_lines") else f"{a['missing_lines']}줄({a['missing_chars']}자)"
    mixed = ", ".join(f"{k} {v}" for k, v in a["mixed"].items()) or "없음"
    photo = f"우리 {a['ours_img']}장·설명 {a['ours_cap']} / 사이트 {s.get('imgs', '?')}장·설명 {s.get('caps', '?')}"
    if a.get("cap_as_p"):
        photo += f" · 설명이 문단으로 {a['cap_as_p']}"
    memo = []
    if not s.get("error"):
        if s.get("heads") or a["ours_h"]:
            memo.append(f"소제목 우리 {a['ours_h']}/사이트 {s['heads']}")
        if s.get("lists") or a["ours_li"]:
            memo.append(f"목록 {a['ours_li']}/{s['lists']}")
        if s.get("quotes") or a["ours_quote"]:
            memo.append(f"인용 {a['ours_quote']}/{s['quotes']}")
        if s.get("tables"):
            memo.append(f"표 {s['tables']}(앱은 표 블록 없음)")
        if s.get("embeds"):
            memo.append("끼운 것 " + ",".join(sorted(set(s["embeds"]))))
        if s.get("more"):
            memo.append("'더 보기' 있음")
        if s["page"].get("paywall") or s["page"].get("loginWall"):
            memo.append("유료·로그인 표시")
    if a.get("cover_note"):
        memo.append("표지 " + a["cover_note"])
    if a.get("hidden_by_reader"):
        memo.append(f"읽기 창이 숨기는 블록 {a['hidden_by_reader']}")
    memo.append(f"{a['path']} {a['sec']}초")
    return f"| [기사 {n}]({a['link']}) | {a['path']} | {pct} | {miss} | {esc(mixed)} | {esc(photo)} | - | {esc(' · '.join(memo))} |"


def main(listfile, cmpf, notesf, outdir):
    rows = [l.rstrip("\n").split("\t") for l in open(listfile, encoding="utf-8") if l.strip()]
    data = json.load(open(cmpf, encoding="utf-8"))
    notes = json.load(open(notesf, encoding="utf-8"))
    by = {}
    for a in data["articles"]:
        by.setdefault(a["sid"], []).append(a)
    summary = []
    kinds = Counter()
    for sid, name, kind, on, pay, url in rows:
        arts = by.get(sid, [])
        note = notes.get(sid, {})
        f = data["feeds"].get(sid, {})
        v = verdict(arts, note)
        cov = med([a.get("coverage") for a in arts])
        pct = med([a.get("pct") for a in arts])
        mixed = Counter()
        for a in arts:
            mixed.update(a["mixed"])
        for k in mixed:
            if k not in note.get("ignore", []):
                kinds["섞임: " + k] += 1
        for k in note.get("kinds", []):
            kinds[k] += 1
        paid_obs = note.get("paywall_seen", "없음(전문 공개)" if arts and not any(a.get("site", {}).get("page", {}).get("paywall") for a in arts) else "확인 필요")
        L = [f"# {name} (`{sid}`)", ""]
        L += [f"- 종류: {kind} · 기본켜짐: {'예' if on == '기본켜짐' else '아니오'} · 지금 paywall 값: {pay if pay != '-' else '없음'} → 관찰한 유료 상태: {paid_obs}",
              f"- 판정: **{v}** — {note.get('why', '')}".rstrip(" —"),
              f"- 기사 {len(arts)}건 · 완전성(우리/사이트 글자) 중앙값 {pct if pct is not None else '-'}% · 사이트 문단 대조 중앙값 {cov if cov is not None else '-'}%",
              "- 점검: 2026-10-15, 앱 추출기(ReadSweep 와 같은 `ArticleExtractor.extract(allowScripts: true)`) + 헤드리스 Chromium(본문 상자 선택자는 tools/kr2/sitemeasure.js)", ""]
        L += ["## 피드로 넘어오는 것", ""]
        if f.get("error") or not f.get("n"):
            L += [f"- 피드 받기·풀기: {f.get('error') or '항목 없음'}", ""]
        else:
            L += [f"- {f['format'].upper()} · 항목 {f['count']}개{' · 주소가 ' + '/'.join(map(str, f['redirects'])) + ' 로 옮겨짐' if f.get('redirects') else ''}{' · XML 이 엄격 풀이에 실패(맨 & — 앱은 너그럽게 읽음)' if f.get('xml_error') else ''}",
                  f"- 요약: 길이 중앙값 {f['desc_med']}자(최대 {f['desc_max']}) · HTML 든 요약 {f['desc_html']}/{f['n']} · 전문(content:encoded) 중앙값 {f['encoded_med']}자",
                  f"- 사진: {f['img_items']}/{f['n']}건에 있음 · 출처 {', '.join(f['img_from']) or '없음'}{' · 크기 표시 ' + ', '.join(f['img_wh']) if f['img_wh'] else ''}",
                  f"- 날짜 `{esc(f['date'])}` 꼴 · 분야 {f['cats']}/{f['n']} · 기자 칸 {f['author']}/{f['n']} · 링크 꼴 `{f['link_sample']}`", ""]
        for x in note.get("feed", []):
            L.append(f"- {x}")
        if note.get("feed"):
            L.append("")
        L += ["## 기사별", "", "| 기사(주소) | 얻은 길 | 우리 글자 / 사이트 글자 (%) | 빠진 것 | 섞인 것 | 사진 | 번역 | 메모 |", "|---|---|---|---|---|---|---|---|"]
        for i, a in enumerate(arts, 1):
            L.append(art_row(a, i))
        if not arts:
            L.append("| - | - | - | - | - | - | - | 기사를 얻지 못함(위 피드 항목 참고) |")
        L += ["", "- '우리'는 읽기 창이 실제로 보여 줄 블록 — 추출 결과에서 읽기 창이 숨기는 것(BodyCleanup 의 '이름 기자 메일' 줄·짝 잃은 사진 설명, ImageKey.isJunk 그림)을 뺀 뒤 잼.",
              "- 글자는 공백을 뺀 수. 우리 글자에는 사진 설명·끝 꼬리(저작권 등)가 들어가고, 사이트 글자는 본문 상자 안 보이는 글 전부.",
              "- '문단 대조'는 사이트 본문 상자의 20자 넘는 줄 가운데 앞 25자가 우리 본문에 있는 비율(빠진 것의 척도). '섞인 것'은 우리 블록 가운데 종류 규칙에 걸린 수.", ""]
        if note.get("observed"):
            L += ["## 본 것", ""] + [f"- {x}" for x in note["observed"]] + [""]
        ignore = set(note.get("ignore", []))
        tail = [k for k in mixed if k in TAIL and k not in ignore]
        auto = [] if note.get("rules") else [RULE[k] for k in mixed if k in RULE and k not in TAIL and k not in ignore and k != "본문 상자 밖 글(기타)"]
        rules = note.get("rules", []) + auto + (["공통 끝 꼬리 정리(" + "·".join(tail) + ") — 출처별이 아닌 공통 규칙"] if tail else [])
        L += ["## 필요한 규칙(제안)", ""] + ([f"- {r}" for r in rules] or ["- 없음(지금 그대로 좋음)"]) + [""]
        if note.get("shots"):
            L += ["스크린샷(저장소 밖 srcaudit-shots/kr2): " + ", ".join(note["shots"]), ""]
        open(f"{outdir}/{sid}.md", "w", encoding="utf-8").write("\n".join(L))
        top = ", ".join(f"{k} {v}" for k, v in mixed.most_common(3)) or "-"
        summary.append((sid, name, v, pct, cov, note.get("main", top), (rules[0].split(" — ")[0] + (f" 외 {len(rules) - 1}" if len(rules) > 1 else "")) if rules else "-"))
    S = ["# 출처 점검 KR2 묶음 요약", "", f"- 2026-10-15 · 출처 {len(rows)}곳 · 기사 {sum(len(v) for v in by.values())}건 · 출처마다 최근 기사 3건(긴 기사·사진 있는 기사·짧은 기사 섞음)",
         "- 방법·도구: `tools/kr2/`(README). 기사 본문·스크린샷은 저장소에 넣지 않음.", "",
         "| 출처 | 판정 | 완전성 중앙값 | 문단 대조 | 주요 문제 | 제안 규칙 |", "|---|---|---|---|---|---|"]
    for sid, name, v, pct, cov, top, rules in summary:
        S.append(f"| [{name}]({sid}.md) | {v} | {pct if pct is not None else '-'}% | {cov if cov is not None else '-'}% | {esc(top)} | {esc(rules)} |")
    S += ["", "## 판정 수", ""] + [f"- {k}: {v}곳" for k, v in Counter(x[2] for x in summary).most_common()]
    S += ["", "## 문제 종류별 출처 수", "", "| 종류 | 출처 수 |", "|---|---|"] + [f"| {k} | {v} |" for k, v in sorted(kinds.items(), key=lambda kv: (-kv[1], kv[0]))]
    S += [""] + notes.get("_summary", [])
    open(f"{outdir}/_KR2.md", "w", encoding="utf-8").write("\n".join(S) + "\n")


if __name__ == "__main__":
    main(*sys.argv[1:5])
