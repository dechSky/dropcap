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

    public static bool IsOrphanCaption(string text, bool nextIsImage) =>
        !nextIsImage && text.Length <= 40 && OrphanCaption.IsMatch(text);

    // 본문에서 뺄 문단 번호와 바이라인(여러 명이면 이어 붙임)
    public static (HashSet<int> Skip, string? Byline) Analyze(IReadOnlyList<Block> blocks)
    {
        var skip = new HashSet<int>();
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
