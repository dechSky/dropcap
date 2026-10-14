using Dropcap.Core;

namespace Dropcap.Core.Tests;

// 바깥 서버 상태에 따라 흔들리므로 DROPCAP_LIVE_TESTS=1 일 때만 돈다(Q-02)
public sealed class LiveFactAttribute : FactAttribute
{
    public LiveFactAttribute()
    {
        if (Environment.GetEnvironmentVariable("DROPCAP_LIVE_TESTS") != "1") Skip = "DROPCAP_LIVE_TESTS=1 일 때만";
    }
}

public sealed class LiveTheoryAttribute : TheoryAttribute
{
    public LiveTheoryAttribute()
    {
        if (Environment.GetEnvironmentVariable("DROPCAP_LIVE_TESTS") != "1") Skip = "DROPCAP_LIVE_TESTS=1 일 때만";
    }
}

// 실제 네트워크로 기본 출처를 받아 본다(안전 검사가 정상 출처를 막지 않는지)
public class LiveFeedTests
{
    [LiveFact]
    public async Task DefaultSourcesLoad()
    {
        var failures = new List<string>();
        foreach (var src in Resources.Config.Sources.Where(s => s.DefaultOn))
        {
            try
            {
                var items = await FeedService.Shared.ItemsAsync(src, conditional: false) ?? [];
                if (items.Count == 0) failures.Add($"{src.Id}: 0건");
            }
            catch (Exception e) { failures.Add($"{src.Id}: {e.Message}"); }
        }
        Assert.True(failures.Count == 0, string.Join(", ", failures));
    }
}

// 실제 네트워크로 주소 해석기를 확인한다
public class ChannelResolverTests
{
    [LiveTheory]
    [InlineData("cs.CL", ItemKind.Paper)]
    [InlineData("https://github.com/ollama/ollama", ItemKind.Release)]
    [InlineData("https://www.youtube.com/@TwoMinutePapers", ItemKind.Video)]
    [InlineData("simonwillison.net", ItemKind.Article)]
    [InlineData("https://www.latent.space", ItemKind.Article)]
    public async Task Resolves(string input, ItemKind kind)
    {
        var f = await ChannelResolver.ResolveAsync(input);
        Assert.True(f.Kind == kind, $"{input} → {f.FeedUrl}");
        Assert.StartsWith("https://", f.FeedUrl);
    }

    [LiveFact]
    public async Task RejectsPrivate() =>
        await Assert.ThrowsAnyAsync<Exception>(() => ChannelResolver.ResolveAsync("http://192.168.0.1/feed"));

    [LiveFact]
    public async Task CatalogFeedsLoad()
    {
        var bad = new List<string>();
        foreach (var s in ChannelCatalog.All.Where(s => !s.Url.Contains("reddit.com"))) // 레딧은 연속 요청을 막을 때가 많아 제외
        {
            try
            {
                if ((await FeedService.Shared.ItemsAsync(s, conditional: false) ?? []).Count == 0 && s.Kind != "paper") bad.Add(s.Name + ": 0건");
            }
            catch (Exception e) { bad.Add($"{s.Name}: {e.Message}"); }
        }
        Assert.True(bad.Count == 0, string.Join(", ", bad));
    }
}

public class UrlSafetyDnsTests
{
    // 이름이 내부망 IP 로 풀리면 거절(실제 DNS 조회, 네트워크 필요)
    [LiveFact]
    public async Task NameResolvingToLoopbackIsBlocked()
    {
        Assert.False(await UrlSafety.ResolvesPublicAsync("http://127.0.0.1.nip.io/"));
        Assert.False(await UrlSafety.ResolvesPublicAsync("http://localtest.me/"));
        // 연결 콜백도 같은 이름을 거절(S-03)
        Assert.Null(await SafeHttp.ResolveCheckedAsync("127.0.0.1.nip.io", default));
        await Assert.ThrowsAsync<BlockedException>(() => FeedService.Shared.FetchAsync("http://localtest.me/"));
    }

    [LiveFact]
    public async Task PublicNameAllowed() => Assert.True(await UrlSafety.ResolvesPublicAsync("https://openai.com/"));

    // 공개 주소에서 내부망으로 넘기는 리다이렉트는 따라가지 않는다(S-04)
    [LiveFact]
    public async Task RedirectToPrivateBlocked() =>
        await Assert.ThrowsAsync<BlockedException>(() => FeedService.Shared.FetchAsync("https://httpbin.org/redirect-to?url=http%3A%2F%2F127.0.0.1%2F"));

    [LiveFact]
    public async Task GoogleTranslateWorks()
    {
        var o = await Translator.Shared.TranslateManyAsync(["OpenAI releases a new model.", "It is fast."]);
        Assert.All(o, t => Assert.False(Translator.LooksForeign(t)));
        Assert.Equal(Translator.EngineGoogle, Translator.Shared.LastEngine);
    }
}
