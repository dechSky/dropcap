#!/usr/bin/env python3
"""출처 추가 점검 결과(app-<id>.json · site-<id>.json)와 판정 메모(verdicts.json)로 mac/sources-audit/<id>.md 를 만든다.
본문·기자 이름은 쓰지 않는다(글자 수·꼴만).  쓰기: python3 -I gen_md.py <결과 폴더> <verdicts.json> <출력 폴더>"""
import json, os, sys
from statistics import median

res, verdicts, outdir = sys.argv[1], json.load(open(sys.argv[2], encoding="utf-8")), sys.argv[3]
cands = {c["id"]: c for c in json.load(open(os.path.join(os.path.dirname(__file__), "candidates.json"), encoding="utf-8"))}
PATH = {"fast": "빠른 길", "slow": "느린 길", "none": "실패"}

def load(name):
    p = os.path.join(res, name)
    return json.load(open(p, encoding="utf-8")) if os.path.exists(p) else None

for sid, v in verdicts.items():
    c = cands[sid]
    app = load(f"app-{sid}.json") or {"feed": {}, "articles": []}
    site = load(f"site-{sid}.json") or []
    f = app["feed"]
    lines = [f"# {c['name']} (`{sid}`) — 추가 점검", "",
             f"- 종류: {c['type']} · 분야 {c['section']} · {c['region']} · 주소 `{c['url']}`" + (f" · 거르기 `{c['match']}`" if c.get('match') else ""),
             f"- 기본켜짐: false(추가 출처는 모두 꺼진 채로) · paywall 값: {c.get('paywall') or '없음'} → 관찰: {v['observed']}",
             f"- **판정: {v['verdict']}** · {'넣음' if v['add'] else '뺌'} — {v['why']}", "",
             "## 1. 피드로 넘어오는 것", "",
             f"- 앱 피드 읽기: {'성공' if f.get('ok') else '실패 ' + str(f.get('error'))} · 글 {f.get('count', 0)}건 · 날짜 {f.get('dated', 0)}건"
             + (f" · 가장 최근 {f['newestHours']:.1f}시간 전" if f.get('newestHours') is not None else "")
             + f" · 사진 {f.get('withImage', 0)}건 · 요약 길이 중앙값 {f.get('summaryMedian', 0)}자",
             ]
    if v.get("feedNote"): lines.append(f"- {v['feedNote']}")
    lines += ["", "## 2~4. 앱이 얻은 본문 vs 실제 사이트", "",
              "| 기사(주소) | 얻은 길 | 우리 글자 / 사이트 글자 (%) | 유료 판정(앱·사이트) | 사이트 문단·소제목·사진 | 메모 |",
              "|---|---|---|---|---|---|"]
    ratios = []
    for i, a in enumerate(app["articles"]):
        s = site[i] if i < len(site) else {}
        sc = s.get("chars") or 0
        off = bool(sc) and (sc < 200 or a["chars"] / sc > 1.5)  # 사이트 선택자가 본문 일부만 잡음
        pct = (f"{round(100 * a['chars'] / sc)}%" + (" 측정 빗나감" if off else "")) if sc else "—"
        if sc and not off: ratios.append(a["chars"] / sc)
        t = a["trace"]
        how = PATH.get(t.get("path"), t.get("path"))
        if t.get("http"): how += f"(빠른 길 {t['http']})"
        if t.get("skipped"): how += f"·{t['skipped']}"
        wall = ("앱 막힘" if a["paywalled"] else "앱 통과") + " · " + (("벽 " + "/".join(s.get("walls") or []) ) if s.get("walls") else ("captcha" if s.get("captcha") else "벽 없음"))
        shape = f"{s.get('paras', '—')}·{s.get('heads', '—')}·{s.get('photos', '—')}" if s else "측정 못 함"
        memo = (v.get("notes") or {}).get(str(i), "")
        if s.get("status") and s["status"] >= 400: memo = (memo + f" 사이트 {s['status']}").strip()
        lines.append(f"| {a['link']} | {how} {a['seconds']:.1f}초 | {a['chars']} / {sc or '—'} ({pct}) | {wall} | {shape} | {memo} |")
    if ratios: lines += ["", f"완전성 중앙값 {round(100 * median(ratios))}% (사이트 측정이 0 이거나 빗나간 기사는 뺌. 사이트 글자는 본문 영역 선택자 기준이라 ±10% 안팎은 측정 차이)"]
    lines += ["", "## 5. 번역", "", v.get("translate", "국내 출처 — 해당 없음" if c["region"] == "kr" else "영어 기사. 이번 점검에서는 번역을 돌리지 않음(작업자 Translate 몫)."),
              "", "## 6. 필요한 규칙 제안", ""] + [f"- {r}" for r in v.get("rules", ["없음"])] + [""]
    open(os.path.join(outdir, f"{sid}.md"), "w", encoding="utf-8").write("\n".join(lines))
print(len(verdicts))
