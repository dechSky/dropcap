using Dropcap.Core;

namespace Dropcap.Core.Tests;

// 보안 점검 W4 · 번역 방식 고르기(맥과 같은 설정 키 translateEngine: auto · apple · google · off).
// 윈도우엔 기기 내 번역이 없어 auto = Google, apple(맥에서 가져온 '기기 내만')은 보내지 않음.
// '번역 안 함'이면 기사·제목·스토리 비교용 영어 번역까지 아무것도 바깥으로 보내지 않는다.
public class TranslateOffTests
{
    private readonly List<string> sent = new();
    private string mode = "auto";
    private Translator T() => new() { ModeSource = () => mode, Backend = (text, _) => { sent.Add(text); return Task.FromResult<string?>("번역문"); } };

    [Theory]
    [InlineData("off")]
    [InlineData("apple")]
    public async Task OffSendsNothing(string m)
    {
        mode = m;
        var t = T();
        var (texts, engine) = await t.TranslateManyReportingAsync(["Hello world", "Second paragraph"]);
        Assert.Equal(["Hello world", "Second paragraph"], texts);
        Assert.Equal(Translator.EngineNone, engine);
        Assert.Equal("Hello world", await t.TranslateAsync("Hello world"));
        Assert.All(await t.ToEnglishAsync(["한국어 제목"]), Assert.Null);   // 스토리 비교용 영어 번역도 보내지 않음
        Assert.Empty(sent);
    }

    [Fact]
    public async Task OffIgnoresEarlierTranslationsAndSwitchingClearsCache()
    {
        var t = T();
        Assert.Equal(["번역문"], await t.TranslateManyAsync(["Hello world"]));
        Assert.Equal(1, t.CacheCount);
        mode = "off";
        Assert.Equal(["Hello world"], await t.TranslateManyAsync(["Hello world"]));
        Assert.Equal(0, t.CacheCount);                                          // 방식이 바뀌면 캐시를 비움(엔진이 섞이지 않게)
        mode = "google";
        Assert.Equal(["번역문"], await t.TranslateManyAsync(["Hello world"]));
        Assert.Equal(2, sent.Count);
    }

    [Fact]
    public void SettingSurvivesFilesAndUnknownIsAuto()
    {
        Assert.Equal("auto", StateSettings.FromJson(new System.Text.Json.Nodes.JsonObject()).TranslateEngine);   // 예전 파일
        var s = new AppState();
        s.Settings.TranslateEngine = "off";
        Assert.Equal("off", AppState.FromJson(s.ToJson()).Settings.TranslateEngine);
        Assert.Equal("apple", StateSettings.FromJson(new System.Text.Json.Nodes.JsonObject { ["translateEngine"] = "apple" }).TranslateEngine); // 맥 값 그대로 지킴
        Assert.Equal("auto", StateSettings.FromJson(new System.Text.Json.Nodes.JsonObject { ["translateEngine"] = "deepl" }).TranslateEngine);
    }
}
