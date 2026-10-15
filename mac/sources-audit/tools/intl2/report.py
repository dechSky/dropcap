#!/usr/bin/env python3
"""INTL2 md 만들기: digest.json(compare.py) + feeds.json + notes-intl2.json → mac/sources-audit/<id>.md · _INTL2.md
쓰는 법: python3 -I report.py <작업폴더> <sources-audit 폴더> <주소 목록 파일(저장소 밖)>
기사 본문·기자 이름은 쓰지 않는다. 기사 주소는 이름이 든 slug 가 있어 md 에는 호스트+번호만, 전체 주소는 저장소 밖 파일에."""
import json, re, sys, statistics as st, os
from urllib.parse import urlparse

W, OUT, URLS = sys.argv[1], sys.argv[2], sys.argv[3]
here = os.path.dirname(os.path.abspath(__file__))
notes = json.load(open(f"{here}/notes-intl2.json"))
feeds = {f["id"]: f for f in json.load(open(f"{W}/feeds.json"))}
dig = json.load(open(f"{W}/digest.json"))
replay = json.load(open(f"{W}/replay.json"))
sweep = {}
for r in json.load(open(f"{W}/sweep-intl2.json")): sweep.setdefault(r["target"]["link"], r)
srcs = [l.rstrip("\n").split("\t") for l in open(f"{here}/../../../../../assign/srcaudit-INTL2.txt", encoding="utf-8")] if os.path.exists(f"{here}/../../../../../assign/srcaudit-INTL2.txt") else None

def short(u):
    p = urlparse(u)
    segs = [s for s in p.path.split("/") if s]
    keep = [s if (re.fullmatch(r"[0-9a-z]{0,14}\d[0-9a-z]*|news|articles|video|videos|sport|story|id|blog|index|live|sounds|play|[a-z]{2,12}", s) and len(s) <= 14) else "…" for s in segs]
    return p.netloc.replace("www.", "") + "/" + "/".join(keep)

def kind_label(i):
    return ["가장 최신", "가장 긴 요약", "가장 짧은 요약"][i] if i < 3 else ""

lines_urls = []
summary_rows = []
counts = {"cut": {}, "mix": {}, "paywall": [], "translate": []}
for sid, name, kind, on, pay, feed in srcs:
    n = notes[sid]; f = feeds[sid]
    targets = [x["target"] for x in replay if x["target"]["sourceId"] == sid]
    rows, pcts = [], []
    for i, t in enumerate(targets):
        link = t["link"]; d = dig.get(link, {}); r = sweep.get(link)
        lines_urls.append(f"{sid}\t{i+1}\t{link}")
        a = d.get("app") or {}
        if sid == "bbc-tech" and i == 0: d = dig.get(link, {})
        path = (f"{a.get('path')} {a.get('seconds')}초" if a.get("ok") else f"실패({a.get('reason') or '?'})") if a else "-"
        s = d.get("site") or {}
        blocked_site = d.get("captcha") or d.get("status") in (401, 403) or not s.get("chars")
        gated = bool(d.get("paywallEl") or d.get("paywallText"))
        if a.get("ok") and not blocked_site:
            pct, cov = d.get("pct"), min(d.get("coverPct") or 0, 100)
            if not gated and s["chars"] >= 300: pcts.append(cov)
            comp = f"{a['chars']:,} / {s['chars']:,} ({pct}%) · 일치 {cov}%" + (" · 사이트는 구독 문 뒤 일부만" if gated else "") + (" · 기사 아닌 페이지" if s["chars"] < 300 else "")
        elif a.get("ok"):
            comp = f"{a['chars']:,} / 비교 불가({'확인 화면' if d.get('captcha') or d.get('status') in (401,403) else '영역 못 찾음'})"
        else:
            comp = f"0 / {s['chars']:,}" if s.get("chars") else "0 / 비교 불가"
        miss = d.get("missing") or {}
        missing = "-" if not a.get("ok") else (f"{miss.get('n',0)}블록 {miss.get('chars',0):,}자" if miss.get("n") and not blocked_site else "없음" if not blocked_site else "?")
        if a.get("ok") and not blocked_site:
            dh = (s.get("heads") or 0) - a.get("heads", 0)
            if dh > 0: missing += f" · 소제목 −{dh}"
        mixed = d.get("mixed") or []
        mixs = "-" if not a.get("ok") else (f"{len(mixed)}블록" if not blocked_site else "(앱 결과로 판정)")
        photo = "-" if not a.get("ok") else f"우리 {a.get('imgs',0)}(설명 {a.get('caps',0)}) / 사이트 {s.get('imgs','?')}(설명 {s.get('caps','?')}) · 표지 {a.get('cover') or '-'} {a.get('coverSize') or ''}".strip()
        memo = n["memo"][i] if i < len(n["memo"]) else ""
        rows.append(f"| {i+1}. {kind_label(i)} `{short(link)}` | {path} | {comp} | {missing} | {mixs} | {photo} | {'아래' if a.get('ok') else '-'} | {memo} |")
    med = int(st.median([p for p in pcts if p is not None])) if [p for p in pcts if p is not None] else None
    flags = []
    cookie = any((dig.get(t["link"], {}) or {}).get("cookie") for t in targets)
    md = f"# {name} (`{sid}`)\n\n"
    md += f"- 종류: {kind} · 기본켜짐: {'예' if on != '-' else '아니오'} · 지금 paywall 값: `{pay}`\n"
    md += f"- 관찰한 유료 상태: {n['observedPaywall']}\n"
    md += f"- **판정: {n['verdict']}** · 완전성 중앙값(사이트 본문 가운데 우리가 얻은 비율 · 구독 문·기사 아닌 페이지 제외): {str(med) + '%' if med is not None else '비교 불가'}\n"
    md += f"- 잰 때: 2026-10-15 · 기사 {len(targets)}건(최신 10건 중 가장 최신·요약 가장 긴 것·가장 짧은 것) · 전체 주소는 저장소 밖 `srcaudit-shots/intl2/urls.tsv` · 스크린샷 `{sid}-1~3.png`\n\n"
    md += "## 피드로 넘어오는 것\n\n" + n["feed"] + "\n\n"
    it = f.get("items", [])
    if it:
        md += f"- 형식 {f.get('format')} · 항목 {f.get('count')}건 · 최신 10건 기준: 요약 중앙값 {int(st.median([x['summaryChars'] for x in it]))}자(HTML {sum(x['summaryHtml'] for x in it)}/10) · 전문(content) 중앙값 {int(st.median([x['contentChars'] for x in it]))}자 · 사진 {sum(bool(x['images']) for x in it)}/10 · 기자 {sum(x['hasAuthor'] for x in it)}/10 · 분야 {sum(bool(x['categories']) for x in it)}/10\n\n"
    md += "## 기사별\n\n| 기사(주소) | 얻은 길 | 우리 글자 / 사이트 글자 (%) | 빠진 것 | 섞인 것 | 사진 | 번역 | 메모 |\n|---|---|---|---|---|---|---|---|\n" + "\n".join(rows) + "\n\n"
    md += "- 글자: 읽기 창이 숨기는 블록(BodyCleanup·표지 중복·잡그림)을 뺀 문단·소제목·목록·인용 글자 / 사이트 본문 영역의 같은 종류 글자(관련·뉴스레터·공유·바이라인 상자 안 글 제외). 100% 를 넘으면 섞인 것이 있거나 사이트가 일부만 보여 준 것. '일치' = 우리 글 가운데 사이트 본문에도 있는 글자 / 사이트 글자(완전성, 100% 상한).\n"
    md += "- 섞인 것: 우리 블록 가운데 사이트 본문 글에 없는 것의 수(종류는 아래 '관찰').\n"
    md += f"- 쿠키 동의창: {'있음' if cookie else '안 보임'}(헤드리스·en-US 기준).\n\n"
    md += "## 관찰\n\n" + "\n".join(f"- {x}" for x in n["issues"]) + "\n\n"
    md += f"## 번역\n\n- {n['translate']} (번역은 실행하지 않고 블록 구조로 본 위험만 — 자세한 것은 작업자 Translate)\n\n"
    md += "## 필요한 규칙(제안)\n\n" + "\n".join(f"- {x}" for x in n["rules"]) + "\n"
    open(f"{OUT}/{sid}.md", "w").write(md)
    summary_rows.append((sid, name, n, med))
    for c in n["cause"]: counts["cut"].setdefault(c, []).append(sid)
    for m in n["mix"]: counts["mix"].setdefault(m, []).append(sid)
    if "→" in n["observedPaywall"] or "metered(구독 문)" in n["observedPaywall"] or "**metered" in n["observedPaywall"]: counts["paywall"].append(sid)
open(URLS, "w").write("\n".join(lines_urls) + "\n")
json.dump({"rows": [(a, b, c["verdict"], d) for a, b, c, d in summary_rows], "counts": counts}, open(f"{W}/summary.json", "w"), ensure_ascii=False, indent=1)
print("ok", len(summary_rows))
