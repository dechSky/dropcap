#!/usr/bin/env python3
"""_ADD.md 의 후보 표를 만든다(candidates.json + verdicts.json + 하루 글 수 어림 rates.json).
쓰기: python3 -I gen_add.py > 표.md"""
import json, os
here = os.path.dirname(os.path.abspath(__file__))
C = json.load(open(os.path.join(here, "candidates.json"), encoding="utf-8"))
V = json.load(open(os.path.join(here, "verdicts.json"), encoding="utf-8"))
R = json.load(open(os.path.join(here, "rates.json"), encoding="utf-8"))
SEC = {"top": "주요", "politics": "정치", "economy": "경제", "society": "사회", "world": "국제", "tech": "IT", "ai": "AI", "science": "과학", "life": "생활", "culture": "문화", "sports": "스포츠", "climate": "기후"}
print("| 결과 | id | 이름 | 지역·분야 | 종류·주소 | 유료(paywall) | 하루 글(어림) | 판정 | 이유 |")
print("|---|---|---|---|---|---|---|---|---|")
for c in sorted(C, key=lambda c: (not V[c["id"]]["add"], c["region"], c["section"])):
    v = V[c["id"]]
    print(f"| {'**넣음**' if v['add'] else '뺌'} | [`{c['id']}`]({c['id']}.md) | {c['name']} | {c['region']}·{SEC[c['section']]} | {c['type']} `{c['url']}` | {c.get('paywall') or '없음'} | {R.get(c['id'], '—')} | {v['verdict']} | {v['why']} |")
