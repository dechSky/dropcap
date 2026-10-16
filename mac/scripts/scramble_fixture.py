#!/usr/bin/env python3
"""기사 페이지의 꼴(태그·class)만 남기고 글·주소를 모두 바꾼 시험용 HTML 을 만든다(mac/READER-CUT.md).

공개 저장소에 기사 글·기자 이름·주소가 들어가지 않게:
- script·style·svg·noscript·iframe·주석·meta·link 는 버린다(--keep-ld 면 ld+json 의 isAccessibleForFree 만 남김).
- 속성은 class·id·data-component·data-block·itemprop·role·rel 만 남기고, src 는 img.example.com 의 번호 주소로, href 는 /l<번호> 로.
- 글자는 같은 길이·같은 문장부호로 바꾼다(영문 → 정해진 글자 돌림, 한글 → 정해진 음절 돌림, 그 밖의 글자 → '가', 숫자 → 정해진 숫자 돌림
  — 언론사 대표전화·번지가 남지 않게).
- class·id 의 기사 번호(post-123·6자리 넘는 숫자)는 같은 길이의 다른 숫자로, tag-*·category-* 는 tag-t1 꼴로 바꾼다(원본 기사를
  특정하지 못하게). 같은 값은 같은 값으로 바뀌어 class 비교(같은 꼴의 형제 찾기)는 그대로다.
  Readability 의 점수(글 길이·쉼표)는 그대로라 같은 선택을 재현한다.
- --mark '원문 앞부분=표지' 로 그 글이 든 글 조각 앞에 표지 낱말(LEDESTART 등)을 붙여, 시험이 그 문단이 왔는지 본다.

쓰기: python3 -I scramble_fixture.py 원본.html 출력.html [--mark '앞부분=LEDESTART' ...] [--keep-ld]
     이미 만든 시험 HTML 에 숫자·class 규칙만 다시 적용: python3 -I scramble_fixture.py 시험.html 시험.html --rescrub [--keep-ld]
"""
import html
import re
import sys
from html.parser import HTMLParser

DROP = {"script", "style", "svg", "noscript", "iframe", "template", "object", "embed", "canvas", "video", "audio"}
VOID = {"br", "img", "hr", "input", "source", "wbr", "col", "area", "base", "link", "meta", "param", "track"}
KEEP = {"class", "id", "data-component", "data-block", "itemprop", "role", "rel", "type"}
LATIN = "loremipsumdolorsitametconsecteturadipiscingelitseddoeiusmodtemporincididuntutlabore"
HANGUL = "가나다라마바사아자차카타파하거너더러머버서어저처커터퍼허고노도로모보소오조초코토포호"
DIGITS = "7305196824"


class Scrambler(HTMLParser):
    def __init__(self, marks, keep_ld, rescrub=False):
        super().__init__(convert_charrefs=True)
        self.out, self.skip, self.n, self.li, self.hi, self.di = [], 0, 0, 0, 0, 0
        self.marks, self.keep_ld, self.ld, self.rescrub = marks, keep_ld, False, rescrub
        self.found = set()
        self.nums, self.slugs = {}, {}

    # class·id 의 숫자 덩이 → 같은 길이의 다른 숫자(같은 값은 같은 값으로, 서로 다른 값은 다르게)
    def num(self, m):
        d = m.group(0)
        if d not in self.nums:
            used, k = set(self.nums.values()), len(self.nums) + 1
            while True:
                c = str((k * 7919 + 104729) % 10 ** len(d)).zfill(len(d))
                if c != d and c not in used:
                    break
                k += 1000
            self.nums[d] = c
        return self.nums[d]

    def ident(self, v):
        def slug(m):
            key = (m.group(1), m.group(2))
            if key not in self.slugs:
                self.slugs[key] = f"{m.group(1)[0]}{sum(1 for k in self.slugs if k[0] == m.group(1)) + 1}"
            return f"{m.group(1)}-{self.slugs[key]}"
        v = re.sub(r"\b(tag|category)-([a-z0-9-]*[a-z][a-z0-9-]*)", slug, v)
        return re.sub(r"(?<=\bpost-)\d+|(?<=\bpostid-)\d+|\d{6,}", self.num, v)

    def scramble(self, text):
        mark = next((m for k, m in self.marks if k in re.sub(r"\s+", " ", text)), None)
        out = []
        for ch in text:
            if ch.isascii() and ch.isdigit():
                out.append(DIGITS[self.di % len(DIGITS)]); self.di += 1
            elif self.rescrub:
                out.append(ch)
            elif "a" <= ch.lower() <= "z" and ch.isascii():
                c = LATIN[self.li % len(LATIN)]; self.li += 1
                out.append(c.upper() if ch.isupper() else c)
            elif "가" <= ch <= "힣":
                out.append(HANGUL[self.hi % len(HANGUL)]); self.hi += 1
            elif ch.isalpha():
                out.append("가")
            else:
                out.append(ch)
        s = "".join(out)
        if mark:
            self.found.add(mark)
            lead = len(s) - len(s.lstrip())
            s = s[:lead] + mark + " " + s[lead:]
        return html.escape(s, quote=False)

    def attrs(self, tag, attrs):
        keep = []
        for k, v in attrs:
            k = k.lower()
            if k == "src" and tag in ("img", "source"):
                self.n += 1; keep.append(f'src="https://img.example.com/i{self.n}.jpg"')
            elif k == "href":
                self.n += 1; keep.append(f'href="/l{self.n}"')
            elif k in KEEP and v is not None and len(v) < 200:
                if k == "type" and tag != "script":
                    continue
                if k in ("class", "id"):
                    v = self.ident(v)
                keep.append(f'{k}="{html.escape(v)}"')
        return (" " + " ".join(keep)) if keep else ""

    def handle_starttag(self, tag, attrs):
        if tag == "script" and self.keep_ld and dict(attrs).get("type") == "application/ld+json":
            self.ld = True
            return
        if tag in DROP:
            self.skip += 1
            return
        if self.skip or tag in ("meta", "link", "base"):
            return
        self.out.append(f"<{tag}{self.attrs(tag, attrs)}>")

    def handle_startendtag(self, tag, attrs):
        if self.skip or tag in DROP or tag in ("meta", "link", "base"):
            return
        self.out.append(f"<{tag}{self.attrs(tag, attrs)}>")

    def handle_endtag(self, tag):
        if tag == "script" and self.ld:
            self.ld = False
            return
        if tag in DROP:
            self.skip = max(0, self.skip - 1)
            return
        if self.skip or tag in VOID:
            return
        self.out.append(f"</{tag}>")

    def handle_data(self, data):
        if self.ld:
            m = re.search(r'"isAccessibleForFree"\s*:\s*"?(true|false)"?', data, re.I)
            if m:
                self.out.append('<script type="application/ld+json">{"isAccessibleForFree":%s}</script>' % m.group(1).lower())
            return
        if not self.skip:
            self.out.append(self.scramble(data))


def main():
    src, dst = sys.argv[1], sys.argv[2]
    marks, keep_ld, rescrub, args = [], False, False, sys.argv[3:]
    while args:
        a = args.pop(0)
        if a == "--mark":
            k, v = args.pop(0).rsplit("=", 1); marks.append((k, v))
        elif a == "--keep-ld":
            keep_ld = True
        elif a == "--rescrub":
            rescrub = True
    raw = open(src, encoding="utf-8", errors="ignore").read()
    raw = re.sub(r"<!--.*?-->", "", raw, flags=re.S)
    p = Scrambler(marks, keep_ld, rescrub)
    p.feed(raw)
    p.close()
    body = re.sub(r"\n\s*\n+", "\n", "".join(p.out))
    open(dst, "w", encoding="utf-8").write("<!doctype html>\n" + body)
    missing = [m for _, m in marks if m not in p.found]
    print(f"{dst}: {len(body)} bytes" + (f" · 표지 못 붙임: {missing}" if missing else ""))


if __name__ == "__main__":
    main()
