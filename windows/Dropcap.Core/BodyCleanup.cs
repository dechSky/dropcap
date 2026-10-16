using System.Text.RegularExpressions;

namespace Dropcap.Core;

// 본문 다듬기: 기자 이름·이메일 줄은 본문에서 빼서 제목 아래 '바이라인'으로, 사진·영상 없이 남은 짧은 설명 문구는 뺀다(맥 BodyCleanup 과 같은 규칙).
public static class BodyCleanup
{
    // "김가람 기자 reporter@example.com", "이나래 기자 desk@example.com Powered by AI", "홍길동 특파원", "By Jane Doe"
    private static readonly Regex Byline = new(@"^\s*(?:\[[^\]]{1,20}\]\s*)?([가-힣]{2,4})\s?(기자|특파원|에디터|선임기자|객원기자|논설위원)(?:\s*[=·,]?\s*[\w.+-]+@[\w-]+(?:\.[\w-]+)+)?(?:\s*Powered by [\w .]{1,40})?\s*$");
    private static readonly Regex EnglishByline = new(@"^\s*By\s+[A-Z][a-z]+(?:\s+[A-Z][a-z.]+){0,3}\s*$");
    // 사진·영상 설명만 남은 줄: "AI 생성 영상", "사진=연합뉴스", "(사진 제공: ○○)", "그래픽=○○"
    private static readonly Regex OrphanCaption = new(@"^\s*[\(\[]?\s*(?:AI\s?생성\s?(?:영상|이미지|사진)|(?:사진|영상|이미지|그래픽|자료)\s?(?:=|제공|출처|:)[^.。]{0,30})\s*[\)\]]?\s*$");

    public static string? BylineOf(string text)
    {
        var m = Byline.Match(text);
        if (m.Success) return $"{m.Groups[1].Value} {m.Groups[2].Value}";
        return EnglishByline.IsMatch(text) ? text.Trim() : null;
    }

    // 군더더기 줄(sources-audit _KR1·_KR2·_INTL1·_INTL2 '섞여 들어온 것'): 짧은 줄만, 글자째 맞을 때만(맥 BodyCleanup.junkLine 과 같은 규칙)
    private static readonly Regex JunkLine = new("""
        ^\s*(?:
          [\w.+-]+@[\w-]+(?:\.[\w-]+)+ | \S{1,20}\s+[\w.+-]+@[\w-]+(?:\.[\w-]+)+                # 메일만 · 매체명+메일
        | (?:좋아요|슬퍼요|화나요|추천해요|최고예요|후속\s?기사\s?원해요)\s*\d                      # 반응 단추
        | (?:입력|수정|발행일?|승인|업데이트|등록|기사\s?입력)\s*:?\s*\d{4}[.\-/]                  # 입력·수정일 줄
        | (?:Copyright\s*(?:©|\(c\)|\d{4})|ⓒ|©) | .*(?:All\ rights\ reserved|무단\s?전재|재배포\s?금지)  # 저작권 줄
        | Follow\ topics\ and\ authors | Email\ \(required\) | View\ Bio$ | Most\ read | Recommended\ Stories$
        | \d[\d,]*\s+Comments?$ | 댓글\s*\d*$ | 많이\ 본\ (?:뉴스|기사) | 에디터\ 픽
        | Listen\ to\ (?:this\ )?article | 기사\s?듣기 | Your\ browser\ does\ not\ support\ the\ (?:audio|video)
        | To\ view\ this\ video\ please\ enable\ JavaScript | Video\ Player\ is\ loading | \[\[duration\]\]
        | When\ you\ purchase\ through\ links | Sign\ up\ for\ (?:our|the) | Get\ the\ latest\ updates\ from | Already\ have\ an\ account
        | Skip\ to\ (?:main\ )?content | This\ content\ is\ generated\ by | Embed\ <iframe | .*\[email\ protected\]
        | 제보는\ 카카오톡 | URL이\ 복사되었습니다 | 공유(?:하기)?$ | 글자\s?크기 | 이\ 기사를\ 추천합니다 | 채널\s?구독
        | 기사\s?스크랩$ | 프린트$ | 인쇄(?:하기)?$ | AI\s?기사\s?요약$ | 기사\s?저장$ | 북마크$
        )
        """, RegexOptions.IgnorePatternWhitespace | RegexOptions.IgnoreCase);
    // 여기서부터 끝까지는 본문이 아님(관련 글·저작권)
    private static readonly Regex TailMark = new(@"^\s*(?:Related content|More on this story|Explore more on these topics|관련\s?기사|많이 본 (?:뉴스|기사)|에디터 픽|Most read|(?:Copyright\s*(?:©|\(c\)|\d{4})|ⓒ|©)|.*(?:All rights reserved|무단\s?전재|재배포\s?금지))", RegexOptions.IgnoreCase);
    private static readonly Regex CopyrightMark = new(@"^\s*(?:Copyright|ⓒ|©)|All rights reserved|무단\s?전재|재배포\s?금지", RegexOptions.IgnoreCase);
    // 기자 소개(머리 세 블록·끝 4분의 1에서만): "… is a senior writer at …", "is a news writer who covers …", "…를 취재합니다"
    private static readonly Regex BioLine = new(@"^(?:(?:[A-Z][\w.'’-]+\s){1,4})?is an?\s(?:[\w-]+\s){0,3}(?:reporter|writer|editor|correspondent|journalist|columnist|producer|contributor)\b|^You can contact or verify outreach|(?:기자입니다|취재합니다|취재하고 있습니다)\.?\s*$", RegexOptions.IgnoreCase);
    private static readonly Regex NameOnly = new(@"^\s*[A-Z][\w.'’-]+(?:\s[A-Z][\w.'’-]+){1,3}\s*$");

    // 본문에서 뺄 군더더기 블록(맥 BodyCleanup.junk). 안전장치: 줄 규칙은 160자 이하 줄만, 끝 자르기는 지울 글이 본문의 20%(저작권 줄이면 50%) 이하일 때만,
    // 줄 규칙이 본문 한가운데서 글의 20% 넘게 지우게 되면 가운데 것은 두고 머리·꼬리 것만 뺀다
    public static HashSet<int> Junk(IReadOnlyList<Block> blocks)
    {
        var text = blocks.Select(b => b.Original ?? b.Text ?? "").ToList();
        var total = Math.Max(1, text.Sum(t => t.Length));
        var n = blocks.Count;
        var tailFrom = (int)(n * 0.75);
        bool Edge(int i) => i < 3 || i >= tailFrom;
        var o = new HashSet<int>();
        for (var i = 0; i < n; i++)
        {
            var t = text[i];
            if (blocks[i].Type == BlockKind.Img || t.Length == 0) continue;
            if (t.Length <= 160 && JunkLine.IsMatch(t)) { o.Add(i); continue; }
            if (Edge(i) && t.Length <= 400 && BioLine.IsMatch(t))
            {
                o.Add(i);
                if (i > 0 && text[i - 1].Length <= 40 && NameOnly.IsMatch(text[i - 1])) o.Add(i - 1);   // 바로 앞 이름 줄
                continue;
            }
            if (i > 0 && t.Length >= 20 && t == text[i - 1]) o.Add(i);   // 같은 글이 잇달아 두 번(부제·사진 설명)
        }
        var middle = o.Where(i => !Edge(i)).ToList();
        if (middle.Sum(i => text[i].Length) > total / 5) o.ExceptWith(middle);
        // 끝 자르기: 뒤쪽 절반에서 처음 나오는 표지부터
        for (var m = n / 2; m < n; m++)
        {
            if (text[m].Length > 160 || !TailMark.IsMatch(text[m])) continue;
            var cut = text.Skip(m).Sum(t => t.Length);
            var copyright = CopyrightMark.IsMatch(text[m]);
            if (cut <= total / 5 || (copyright && cut <= total / 2)) for (var k = m; k < n; k++) o.Add(k);
            break;
        }
        // 이름만 있는 끝 줄(기자 이름 li)이 앞에서 뺀 이름과 같으면
        if (n > 0 && text[n - 1].Length <= 40 && o.Any(i => i != n - 1 && text[i] == text[n - 1])) o.Add(n - 1);
        return o;
    }

    // 번역 전에 군더더기를 아예 뺀다(번역 시간·비용, 번역문에 기사처럼 섞이는 것)
    public static List<Block> DropJunk(IReadOnlyList<Block> blocks)
    {
        var j = Junk(blocks);
        return blocks.Where((_, i) => !j.Contains(i)).ToList();
    }

    public static bool IsOrphanCaption(string text, bool nextIsImage) =>
        !nextIsImage && text.Length <= 40 && OrphanCaption.IsMatch(text);

    // 본문에서 뺄 문단 번호와 바이라인(여러 명이면 이어 붙임)
    public static (HashSet<int> Skip, string? Byline) Analyze(IReadOnlyList<Block> blocks)
    {
        var skip = Junk(blocks);   // 예전에 저장한 기사에도 군더더기 규칙
        var names = new List<string>();
        for (var i = 0; i < blocks.Count; i++)
        {
            var b = blocks[i];
            if (b.Type != BlockKind.P) continue;
            var t = b.Original ?? b.Text ?? "";
            if (BylineOf(t) is { } n) { skip.Add(i); if (!names.Contains(n)) names.Add(n); continue; }
            var next = i + 1 < blocks.Count && blocks[i + 1].Type == BlockKind.Img;
            if (IsOrphanCaption(t, next)) skip.Add(i);
        }
        return (skip, names.Count == 0 ? null : string.Join(" · ", names));
    }

    // 본문에서 빼는 블록(맥 ReaderView.hiddenBlocks): 표지와 같은 사진(주소가 같거나 크기 표기만 다른 것) 처음 한 번, 기자 줄·짝 잃은 설명 문구, 잡그림
    public static HashSet<int> Hidden(IReadOnlyList<Block> blocks, string? cover)
    {
        var o = Analyze(blocks).Skip;
        if (cover is not null)
            for (var i = 0; i < blocks.Count; i++)
                if (blocks[i].Type == BlockKind.Img && ImageKey.Same(blocks[i].Src, cover)) { o.Add(i); break; }
        for (var i = 0; i < blocks.Count; i++)
            if (blocks[i].Type == BlockKind.Img && ImageKey.IsJunk(blocks[i].Src)) o.Add(i);   // 기자 프로필·로고 같은 잡그림은 싣지 않음
        // 뺀 그림 바로 뒤의 사진 설명도 함께 뺀다(사진 없이 설명만 남지 않게)
        foreach (var i in o.ToList())
            if (i + 1 < blocks.Count && blocks[i].Type == BlockKind.Img && blocks[i + 1].Type == BlockKind.Cap) o.Add(i + 1);
        return o;
    }
}
