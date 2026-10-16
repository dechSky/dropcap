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
}
