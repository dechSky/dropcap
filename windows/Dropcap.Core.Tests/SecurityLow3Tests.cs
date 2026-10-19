namespace Dropcap.Core.Tests;

// 보안 점검(2026-10-15) 낮음 X2 — 맥 SecurityLow3Tests 와 같은 규칙
public class SecurityLow3Tests
{
    // 여러 덩어리 모으기의 상자를 살아 있는 문서(document)에 만들면 붙인 <img> 가 받기·onerror 를 돌릴 수 있다(격리 칸 CSP 가 막지만 한 겹 더).
    // 추출 스크립트는 사본(doc·fresh)·DOMParser 문서에서만 노드를 만든다
    [Fact]
    public void ExtractScriptBuildsOnlyInInertDocuments()
    {
        var js = File.ReadAllText(Path.Combine(ExtractJs.Root(), "windows", "Dropcap.Ui", "web", "extract.js"));
        foreach (var live in new[] { "document.createElement", "document.importNode", "document.adoptNode", "document.body.append", "document.write" })
            Assert.DoesNotContain(live, js);
        Assert.Contains("fresh.createElement('div')", js);
    }

    // 행동으로도: CSP 를 뺀 페이지에서 여러 덩어리 모으기(같은 class 형제 상자)를 돌려도
    // 추출하는 동안 그림 받기·onerror 가 일어나지 않는다. 고치기 전(document.createElement) 코드는 요청 2건·onerror 실행
    [JsFact]
    public async Task GatheringDoesNotLoadImagesWithoutCsp()
    {
        static string P(string s) => "<p>" + string.Concat(Enumerable.Repeat(s + " lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor ", 2)) + "</p>";
        var html = "<html><head><title>t</title></head><body><article>"
            + $"<div class=\"chunk\">{P("one")}{P("two")}<img src=\"http://127.0.0.1:9/leak.png\" onerror=\"window.__probe=1\"></div>"
            + "<div class=\"ad\">ad</div>"
            + $"<div class=\"chunk\">{P("three")}{P("four")}<img src=\"http://127.0.0.1:9/leak2.png\" onerror=\"window.__probe=2\"></div>"
            + "</article></body></html>";
        var (requests, onerror) = await ExtractJs.ProbeAsync(html);
        Assert.Equal(0, requests);
        Assert.Null(onerror);
    }
}
