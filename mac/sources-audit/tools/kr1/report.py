#!/usr/bin/env python3
"""KR1 출처 점검 5단계: cmp-<id>.json(compare.py)·feeds.json 과 사람이 적은 notes.json 으로 sources-audit/<id>.md 와 _KR1.md 를 쓴다.
쓰기: python3 -I report.py <결과 폴더> <sources-audit 폴더>
공개 저장소: 기사 본문·기자 이름은 쓰지 않는다 — 빠진 것·섞인 것은 종류와 개수만, 기사는 주소만."""
import json, os, re, statistics, sys
from urllib.parse import urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
PATH = {"fast": "빠른 길", "embedded": "실린 본문 자료", "slow": "느린 길", "none": "실패", "-": "안 잼"}

def norm(s): return re.sub(r"[\s\"'“”‘’·…\.,\-–—]+", "", s or "")

def classify_missing(r):
    caps = set(norm(c)[:25] for c in (r.get("site_caps") or []))
    heads = set(norm(h)[:25] for h in (r.get("site_heads") or []))
    kinds = {}
    for l in r.get("missing", []):
        n = norm(l)[:25]
        if re.search(r"[\w.+-]+@[\w-]+\.", l) or re.search(r"(기자|특파원)\s*$", l): k = "기자 줄"
        elif re.search(r"ⓒ|©|무단|저작권|Copyright", l, re.I): k = "저작권 줄"
        elif any(n in c or c in n for c in caps if c): k = "사진 설명"
        elif any(n in h or h in n for h in heads if h): k = "소제목"
        elif re.search(r"관련\s?기사|많이 본|제보|구독|카카오톡", l): k = "사이트 안내(관련기사·제보 등)"
        elif len(l) < 40: k = "짧은 줄"
        else: k = "본문 문단"
        kinds[k] = kinds.get(k, 0) + 1
    return kinds

def classify_mixed(r):
    kinds = {}
    for m in r.get("mixed", []):
        for k in (m["junk"] or (["본문 영역 밖 줄"] if m["outside"] else [])):
            kinds[k] = kinds.get(k, 0) + 1
    return kinds

def fmt(d): return "·".join(f"{k} {v}" for k, v in d.items()) or "-"

def feed_summary(f):
    s = f.get("sample") or []
    if not s: return f"피드 받기 실패({f.get('error', '?')})"
    lens = [i["desc"]["len"] for i in s]
    full = [i for i in s if i["content"] and i["content"]["len"] > 400]
    html = sum(1 for i in s if i["desc"]["html"])
    imgs = [im for i in s for im in i["images"]]
    tags = sorted(set(im.get("tag") for im in imgs))
    sizes = sorted(set(f"{im.get('w')}×{im.get('h')}" for im in imgs if im.get("w")))
    cats = sum(1 for i in s if i["categories"]); auth = sum(1 for i in s if i["hasAuthor"]); date = sum(1 for i in s if i["date"])
    links = sorted(set(urlparse(i["link"]).netloc for i in s))
    return (f"최근 {len(s)}건 기준 — 요약 길이 중앙값 {int(statistics.median(lens))}자(최대 {max(lens)}) · HTML 든 요약 {html}건 · "
            f"전문(content:encoded 400자 넘음) {len(full)}건 · 사진 {sum(1 for i in s if i['images'])}건({', '.join(t for t in tags if t) or '없음'}"
            + (f"; 크기 표기 {', '.join(sizes[:3])}" if sizes else "") + f") · 분야 {cats}건 · 기자 {auth}건 · 날짜 {date}건 · 링크 호스트 {', '.join(links)}")

def verdict(rows):
    pcts = [r.get("coverage") for r in rows if r.get("coverage") is not None]
    med = statistics.median(pcts) if pcts else None
    bad = any(not r["ok"] for r in rows)
    mixed = sum(len(r.get("mixed", [])) for r in rows)
    if med is None or bad or med < 60: v = "나쁨"
    elif med < 90 or med > 115 or mixed >= 3: v = "부분"
    else: v = "좋음"
    return v, med

def main(d, outdir):
    notes = json.load(open(os.path.join(HERE, "notes.json"))) if os.path.exists(os.path.join(HERE, "notes.json")) else {}
    feeds = json.load(open(f"{d}/feeds.json"))
    summary = []
    for f in feeds:
        rows = json.load(open(f"{d}/cmp-{f['id']}.json")) if os.path.exists(f"{d}/cmp-{f['id']}.json") else []
        n = notes.get(f["id"], {})
        v, med = verdict(rows)
        v = n.get("verdict", v)
        paid = n.get("paywall", "없음(무료로 다 보임)")
        out = [f"# {f['name']} (`{f['id']}`)", "",
               f"- 종류: {f['kind']} · 기본켜짐: {'예' if f['defaultOn'] else '아니오'} · 지금 paywall 값: {f['paywall'] or '없음'} → 관찰한 유료 상태: {paid}",
               f"- **판정: {v}** · 완전성 중앙값 {('%d%%' % med) if med is not None else '-'}(사이트 본문 문단 가운데 우리 글에 든 비율, 글자 기준 — 아래 표의 '덮기')",
               f"- 피드: {feed_summary(f)}", ""]
        if n.get("summary"): out += [n["summary"], ""]
        out += ["| 기사 | 얻은 길 | 우리 / 사이트 글자 (%) · 덮기 | 빠진 것 | 섞인 것 | 사진 | 번역 | 메모 |", "|---|---|---|---|---|---|---|---|"]
        for i, r in enumerate(rows):
            site = r.get("siteClean")
            ratio = f"{r['ourChars']} / {site} ({r.get('pctClean')}%) · {r.get('coverage')}%" if site else f"{r['ourChars']} / - ({r.get('siteErr', '사이트 못 잼')})"
            ph = f"우리 {r['ourImg']}장" + (f"(+표지·숨김 {r['hiddenImg']})" if r.get('hiddenImg') else "") + f"·설명 {r['ourCap']} / 사이트 {r.get('site_bigImgs', '-')}장·설명 {len(r.get('site_caps') or [])}"
            if r.get("orphanCap"): ph += f" · 짝 잃은 설명 {r['orphanCap']}"
            memo = (n.get("articles") or {}).get(str(i + 1), "")
            sec = f" {r['sec']}초" if r.get("sec") is not None else ""
            out.append(f"| [{i + 1}]({r['link']}) | {PATH.get(r['path'], r['path'])}{sec} | {ratio} | {fmt(classify_missing(r))} | {fmt(classify_mixed(r))} | {ph} | {n.get('translate', '해당 없음(국내)')} | {memo} |")
        out += ["", "스크린샷(저장소 밖 srcaudit-shots/kr1): " + ", ".join(f"`{f['id']}-{i + 1}.png`" for i in range(len(rows))), ""]
        out += ["## 필요한 규칙(제안)", ""] + [f"- {x}" for x in (n.get("rules") or ["없음(지금 그대로 좋음)"])] + [""]
        open(f"{outdir}/{f['id']}.md", "w").write("\n".join(out))
        summary.append((f, v, med, n, rows))
    write_summary(summary, outdir)

def write_summary(summary, outdir):
    arts = sum(len(r) for _, _, _, _, r in summary)
    blocked = [f["id"] for f, _, _, n, _ in summary if n.get("blocked")]
    s = ["# KR1 출처 점검 묶음 요약", "",
         f"- 출처 {len(summary)}곳 · 기사 {arts}건 · 차단 {len(blocked)}곳. 방법·도구는 [tools/kr1/README.md](tools/kr1/README.md).",
         "- 판정: " + " · ".join(f"{k} {sum(1 for _, v, _, _, _ in summary if v == k)}" for k in ("좋음", "부분", "나쁨")), ""]
    note = json.load(open(os.path.join(HERE, "notes.json"))).get("_summary", {}) if os.path.exists(os.path.join(HERE, "notes.json")) else {}
    if note.get("intro"): s += note["intro"] + [""]
    s += ["## 출처별", "", "| 출처 | 기본 | 판정 | 완전성 중앙값 | 주요 문제 | 제안 규칙 |", "|---|---|---|---|---|---|"]
    for f, v, med, n, _ in summary:
        s.append(f"| [{f['name']}]({f['id']}.md) | {'켜짐' if f['defaultOn'] else '-'} | {v} | {('%d%%' % med) if med is not None else '-'} | {n.get('problem', '-')} | {n.get('rule', '-')} |")
    s += [""] + note.get("tail", [])
    open(f"{outdir}/_KR1.md", "w").write("\n".join(s) + "\n")

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
