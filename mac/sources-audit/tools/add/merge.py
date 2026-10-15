#!/usr/bin/env python3
"""candidates.json 의 출처를 shared/sources.json 끝에 덧붙인다(기존 항목은 건드리지 않음). 기본 켜짐은 언제나 false.
쓰기: python3 -I merge.py <candidates.json> <sources.json> [넣을 id,…(없으면 전부)]"""
import json, sys
cands = json.load(open(sys.argv[1], encoding="utf-8"))
path = sys.argv[2]
only = set(sys.argv[3].split(",")) if len(sys.argv) > 3 else None
d = json.load(open(path, encoding="utf-8"))
have = {s["id"] for s in d["sources"]}
urls = {s["url"] for s in d["sources"]}
order = ["id", "name", "tier", "type", "url", "match", "aiOnly", "defaultOn", "color", "section", "lang", "region", "paywall"]
for c in cands:
    if (only and c["id"] not in only) or c["id"] in have or c["url"] in urls:
        continue
    c = dict(c, aiOnly=False, defaultOn=False)
    d["sources"].append({k: c[k] for k in order if k in c})
open(path, "w", encoding="utf-8").write(json.dumps(d, ensure_ascii=False, indent=2) + "\n")
print(len(d["sources"]))
