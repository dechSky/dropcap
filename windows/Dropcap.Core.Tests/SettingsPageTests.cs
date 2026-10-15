using System.Text.Json;
using System.Text.Json.Nodes;
using Dropcap.Ui;

namespace Dropcap.Core.Tests;

// 설정 창 처리기(P 절·K 절·G-13): 보기 데이터 모양, 설정 값 검사·저장, 낱말 나누기, 출처 줄
public class SettingsPageTests : IDisposable
{
    private readonly TempDir tmp = new();
    private readonly Database db;
    private readonly FakeUi ui = new();
    private readonly AppModel model;
    private readonly SettingsFakePlatform platform = new();
    private readonly SettingsPage page;

    public SettingsPageTests()
    {
        db = new Database(System.IO.Path.Combine(tmp.Path, "magazine.sqlite"));
        model = new AppModel(ui, new Magazine(db), new AppState(), persist: false) { ShowAllSourcesForTests = true };
        page = new SettingsPage(model, platform);
    }

    public void Dispose() { model.Stop(); db.Dispose(); tmp.Dispose(); }

    private sealed class SettingsFakePlatform : IPlatform
    {
        public int FontApplied;
        public int Onboarding;
        public string? Opened;
        public List<string> Closed { get; } = new();
        public void OpenMagazine(string? page = null) => Opened = "magazine";
        public void OpenSettings(string? tab = null) { }
        public void OpenOnboarding() => Onboarding++;
        public void OpenReader(NewsItem item) { }
        public void CloseWindow(string page) => Closed.Add(page);
        public void Quit() { }
        public void CopyText(string text) { }
        public Task<bool> SaveTextFile(string suggestedName, string text) => Task.FromResult(false);
        public void Share(NewsItem item) { }
        public void Speak(string text, string language) { }
        public void StopSpeaking() { }
        public bool Speaking => false;
        public bool LaunchAtLogin { get; set; }
        public bool ReduceMotion => false;
        public void ApplyFont() => FontApplied++;
    }

    private static JsonNode Json(object? o) => JsonSerializer.SerializeToNode(o, global::Dropcap.Core.Json.Options)!;
    private Task<object?> Do(string cmd, object args) => page.Handle(cmd, (JsonObject)Json(args));
    private Task<object?> SetValue(string key, object value) => Do("set", new { key, value });

    private static Source Custom(string id, string url) => new()
    {
        Id = id, Name = "The Sample", Tier = "press", Type = "feed", Url = url, Color = "#6E56CF", Kind = "post", Group = "직접 추가",
    };

    [Fact]
    public void ViewHasAllSections()
    {
        var v = Json(page.View());
        var g = v["general"]!;
        Assert.Equal([2, 5, 10, 15, 30], g["intervals"]!.AsArray().Select(n => n!["value"]!.GetValue<int>()));
        Assert.Equal("5분", g["intervals"]![1]!["label"]!.GetValue<string>());
        Assert.Equal(["물방울 (앱이 직접 그림)", "시스템 알림 센터"], g["styles"]!.AsArray().Select(n => n!["label"]!.GetValue<string>()));
        Assert.Equal(["위쪽 가운데", "오른쪽 위"], g["positions"]!.AsArray().Select(n => n!["label"]!.GetValue<string>()));
        Assert.Equal("drop", g["style"]!.GetValue<string>());
        Assert.Equal("auto", g["translateEngine"]!.GetValue<string>());   // 번역 엔진 고르기(W4) — 기본은 자동(= Google)
        Assert.True(g["pretendard"]!.GetValue<bool>());

        var s = v["sources"]!;
        Assert.Equal(["기본 출처 · 공식 발표", "기본 출처 · 언론", "기본 출처 · 국내"], s["tiers"]!.AsArray().Select(n => n!["label"]!.GetValue<string>()));
        Assert.Equal(Resources.Config.Sources.Count, s["tiers"]!.AsArray().Sum(n => n!["rows"]!.AsArray().Count));
        Assert.Equal(ChannelCatalog.Groups.Count, s["catalog"]!.AsArray().Count);
        Assert.Equal(ChannelCatalog.All.Count, s["catalog"]!.AsArray().Sum(n => n!["rows"]!.AsArray().Count)); // K-01: 묶음에 빠진 채널 없음
        Assert.Empty(s["custom"]!.AsArray());

        var f = v["filters"]!;
        Assert.Equal(24, f["hours"]!.AsArray().Count);
        Assert.Equal("07:00", f["hours"]![7]!["label"]!.GetValue<string>());
        Assert.Equal(["오전 5시", "오전 6시", "오전 7시", "오전 8시", "오전 9시", "오전 10시", "오전 11시", "낮 12시"],
            f["digestHours"]!.AsArray().Select(n => n!["label"]!.GetValue<string>()));
        Assert.Equal(["Ctrl+Alt+N", "Ctrl+Alt+M"], f["hotkeys"]!.AsArray().Select(n => n!["keys"]!.GetValue<string>()));
    }

    [Fact]
    public async Task SetChangesSettings()
    {
        await SetValue("style", "system");
        await SetValue("position", "right");
        await SetValue("sound", false);
        await SetValue("interval", 15);
        await SetValue("quietEnabled", true);
        await SetValue("quietStart", 22);
        await SetValue("quietEnd", 6);
        await SetValue("digestEnabled", false);
        await SetValue("digestHour", 12);
        var st = model.State.Settings;
        Assert.Equal(ToastStyle.System, st.Style);
        Assert.Equal(ToastPosition.Right, st.Position);
        Assert.False(st.Sound);
        Assert.Equal(15, st.IntervalMinutes);
        Assert.True(st.QuietEnabled);
        Assert.Equal((22, 6), (st.QuietStart, st.QuietEnd));
        Assert.False(st.DigestEnabled);
        Assert.Equal(12, st.DigestHour);
        var g = Json(page.View())["general"]!;
        Assert.Equal("system", g["style"]!.GetValue<string>());
        Assert.Equal("right", g["position"]!.GetValue<string>());
    }

    [Theory]
    [InlineData("interval", 7)]
    [InlineData("quietStart", 24)]
    [InlineData("quietEnd", -1)]
    [InlineData("digestHour", 4)]
    [InlineData("digestHour", 13)]
    [InlineData("nope", 1)]
    public async Task SetRejectsBadValues(string key, int value)
    {
        var before = model.State.Settings.Copy();
        await Assert.ThrowsAnyAsync<Exception>(() => SetValue(key, value));
        Assert.Equal(before.IntervalMinutes, model.State.Settings.IntervalMinutes);
        Assert.Equal(before.DigestHour, model.State.Settings.DigestHour);
        Assert.Equal(before.QuietStart, model.State.Settings.QuietStart);
    }

    [Fact]
    public async Task SetRejectsUnknownStyle() =>
        await Assert.ThrowsAnyAsync<Exception>(() => SetValue("style", "banner"));

    [Fact]
    public async Task FontAndLaunchGoToPlatform()
    {
        await SetValue("pretendard", false);
        Assert.False(Prefs.Get("usePretendard", true));
        Assert.Equal(1, platform.FontApplied);
        Assert.False(Json(page.View())["general"]!["pretendard"]!.GetValue<bool>());

        await SetValue("launchAtLogin", true);
        Assert.True(platform.LaunchAtLogin);
        Assert.True(Json(page.View())["general"]!["launchAtLogin"]!.GetValue<bool>());
    }

    [Fact]
    public void SplitsKeywords()
    {
        Assert.Equal(["GPT-6", "Claude", "오픈소스"], SettingsPage.SplitKeywords(" GPT-6, Claude ,,\n 오픈소스 \n"));
        Assert.Empty(SettingsPage.SplitKeywords(" , \n "));
    }

    [Fact]
    public async Task SavesKeywords()
    {
        var r = Json(await Do("keywords", new { must = "Claude,  Gemini ,", mute = "주식\n채용" }));
        Assert.Equal(["Claude", "Gemini"], model.State.Settings.MustKeywords);
        Assert.Equal(["주식", "채용"], model.State.Settings.MuteKeywords);
        Assert.Equal("Claude, Gemini", r["must"]!.GetValue<string>());
        Assert.Equal("주식, 채용", Json(page.View())["filters"]!["mute"]!.GetValue<string>());
    }

    [Fact]
    public async Task CustomSourceRowAndRemove()
    {
        var src = Custom("custom-x", "https://example.com/feed");
        model.State.CustomSources.Add(src);
        model.State.Enabled[src.Id] = true;
        model.State.Errors[src.Id] = "404";
        var row = Json(page.View())["sources"]!["custom"]![0]!;
        Assert.Equal("S", row["initial"]!.GetValue<string>()); // "The " 를 뺀 첫 글자
        Assert.Equal("커뮤니티", row["kindLabel"]!.GetValue<string>());
        Assert.Equal("확인 실패: 404", row["error"]!.GetValue<string>());
        Assert.Equal("https://example.com/feed", row["sub"]!.GetValue<string>()); // 직접 추가는 home 이 없으면 주소
        Assert.True(row["removable"]!.GetValue<bool>());
        Assert.True(row["enabled"]!.GetValue<bool>());

        await Do("setNotify", new { id = src.Id, on = false });
        Assert.False(model.Notifies(src.Id));
        row = Json(page.View())["sources"]!["custom"]![0]!;
        Assert.Equal("알림 꺼짐 — 매거진에만 실림", row["notifyHelp"]!.GetValue<string>());

        await Do("setEnabled", new { id = src.Id, on = false });
        Assert.False(model.State.Enabled[src.Id]);

        await Do("remove", new { id = src.Id });
        Assert.Empty(model.State.CustomSources);
        Assert.False(model.State.Enabled.ContainsKey(src.Id));
    }

    [Fact]
    public async Task RejectsUnknownSources()
    {
        await Assert.ThrowsAnyAsync<Exception>(() => Do("setNotify", new { id = "nope", on = true }));
        await Assert.ThrowsAnyAsync<Exception>(() => Do("setEnabled", new { id = "nope", on = false }));
        await Assert.ThrowsAnyAsync<Exception>(() => Do("subscribe", new { id = "nope" }));
        // 기본 출처는 해지할 수 없다
        await Assert.ThrowsAnyAsync<Exception>(() => Do("remove", new { id = Resources.Config.Sources[0].Id }));
        Assert.Equal(Resources.Config.Sources.Count, model.AllSources.Count);
    }

    [Fact]
    public void BaseSourceRowHasNoAddress()
    {
        var first = Resources.Config.Sources.First(s => s.Home is null);
        model.State.Enabled[first.Id] = false;
        var rows = Json(page.View())["sources"]!["tiers"]!.AsArray().SelectMany(t => t!["rows"]!.AsArray()).ToList();
        var row = rows.First(r => r!["id"]!.GetValue<string>() == first.Id)!;
        Assert.Null(row["sub"]);
        Assert.False(row["removable"]!.GetValue<bool>());
        Assert.False(row["enabled"]!.GetValue<bool>());
    }

    [Fact]
    public void CatalogShowsSubscribed()
    {
        var cat = ChannelCatalog.All.First(s => s.NotifyDefault == false);
        model.State.CustomSources.Add(Custom("custom-same", cat.Url)); // 주소가 같으면 구독 중
        var rows = Json(page.View())["sources"]!["catalog"]!.AsArray().SelectMany(g => g!["rows"]!.AsArray()).ToList();
        var row = rows.First(r => r!["id"]!.GetValue<string>() == cat.Id)!;
        Assert.True(row["subscribed"]!.GetValue<bool>());
        Assert.Equal("글이 많아 알림 없이 매거진에만 실림", row["sub"]!.GetValue<string>());
        var other = rows.First(r => r!["id"]!.GetValue<string>() != cat.Id)!;
        Assert.False(other["subscribed"]!.GetValue<bool>());
    }

    [Fact]
    public async Task EmptyAddressIsRefusedWithoutNetwork()
    {
        var r = Json(await Do("addChannel", new { input = "   " }));
        Assert.Equal("주소를 넣어 주세요", r["error"]!.GetValue<string>());
        Assert.Empty(model.State.CustomSources);
    }

    [Fact]
    public async Task PreviewMagazineClose()
    {
        await Do("preview", new { });
        Assert.Equal(AppModel.PreviewId, Assert.Single(Assert.Single(ui.Toasts)).Id);
        await Do("magazine", new { });
        Assert.Equal("magazine", platform.Opened);
        await Do("close", new { });
        Assert.Equal(["settings"], platform.Closed);
        await Assert.ThrowsAnyAsync<Exception>(() => Do("nope", new { }));
    }

    // MARK: 분야 탭(G-13)

    private static List<string> Strs(JsonNode n, string key) => n.AsArray().Select(x => x![key]!.GetValue<string>()).ToList();

    [Fact]
    public void SectionsViewShape()
    {
        model.State.SectionsChosen = ["top", "economy", "world", "ai"];
        model.State.SectionPolicy = NotifyPolicy.Defaults(model.State.SectionsChosen);
        var x = Json(page.View())["sections"]!;
        Assert.Equal("고른 분야 3개", x["summary"]!.GetValue<string>()); // 주요 뉴스(흐름)는 세지 않음
        Assert.Equal(["top", "economy", "world", "ai"], Strs(x["rows"]!, "id"));  // 분야 순서대로
        Assert.Equal(["즉시", "묶음", "매거진만"], Strs(x["modes"]!, "label"));
        Assert.Equal(["instant", "bundle", "magazine"], Strs(x["modes"]!, "id"));
        Assert.Equal(Enumerable.Range(6, 18), x["bundleHours"]!.AsArray().Select(n => n!["value"]!.GetValue<int>()));
        Assert.Equal("23:00", x["bundleHours"]![17]!["label"]!.GetValue<string>());
        Assert.Equal(["하루 전체 물방울 10번까지", "국내 3곳 이상 보도면 중요", "해외 2곳 이상 보도면 중요", "국내 8곳 이상이면 상한을 넘어도 알림"],
            Strs(x["limits"]!, "label"));
        Assert.Empty(x["hidden"]!.AsArray());

        var top = x["rows"]![0]!;
        Assert.Equal("주요 뉴스", top["name"]!.GetValue<string>());
        Assert.Equal("star.fill", top["icon"]!.GetValue<string>());
        Assert.Equal("어느 분야든 크게 다룬 소식", top["sub"]!.GetValue<string>());
        Assert.Equal("instant", top["mode"]!.GetValue<string>());

        var eco = x["rows"]![1]!;
        Assert.Equal("cat.business", eco["icon"]!.GetValue<string>());
        Assert.Matches("^#[0-9A-Fa-f]{6}$", eco["color"]!.GetValue<string>());
        var (on, all) = model.SourceCount("economy");
        Assert.Equal(all > 0 ? $"출처 {on}/{all}곳 켜짐" : "구독 탭에서 출처를 켜고 끕니다", eco["sub"]!.GetValue<string>());
        Assert.Equal(all, eco["sourcesAll"]!.GetValue<int>());
        Assert.Equal("하루 3번까지", eco["capLabel"]!.GetValue<string>());
        Assert.Equal("하루 상한을 넘어 고인 소식을 보내는 시각", eco["bundleHelp"]!.GetValue<string>());
        Assert.Equal("instant", x["rows"]![2]!["mode"]!.GetValue<string>());
        Assert.Equal("bundle", x["rows"]![3]!["mode"]!.GetValue<string>()); // 주요 뉴스 빼고 앞 두 분야만 즉시(G-04)
        Assert.Equal("모아 둔 소식을 한 방울로 보내는 시각", x["rows"]![3]!["bundleHelp"]!.GetValue<string>());
    }

    [Fact]
    public void SectionsViewBeforeChoosing()
    {
        var x = Json(page.View())["sections"]!;
        Assert.Equal("아직 관심 분야를 고르지 않았습니다", x["summary"]!.GetValue<string>());
        Assert.Empty(x["rows"]!.AsArray());
    }

    [Fact]
    public async Task SetPolicyChangesSection()
    {
        model.State.SectionsChosen = ["economy"];
        await Do("setPolicy", new { id = "economy", key = "mode", value = "instant" });
        await Do("setPolicy", new { id = "economy", key = "bundleHour", value = 6 });
        await Do("setPolicy", new { id = "economy", key = "dailyCap", value = 10 });
        Assert.Equal(new SectionPolicy { Mode = NotifyMode.Instant, BundleHour = 6, DailyCap = 10 }, model.Policy("economy"));
        await Do("setPolicy", new { id = "economy", key = "mode", value = "magazine" });
        await Do("setPolicy", new { id = "economy", key = "bundleHour", value = 23 });
        var row = Json(page.View())["sections"]!["rows"]![0]!;
        Assert.Equal("magazine", row["mode"]!.GetValue<string>());
        Assert.Equal(23, row["bundleHour"]!.GetValue<int>());
        Assert.Equal(10, row["dailyCap"]!.GetValue<int>()); // 모드를 바꿔도 상한은 그대로
    }

    [Theory]
    [InlineData("economy", "mode", "loud")]
    [InlineData("economy", "bundleHour", 5)]
    [InlineData("economy", "bundleHour", 24)]
    [InlineData("economy", "dailyCap", 0)]
    [InlineData("economy", "dailyCap", 11)]
    [InlineData("economy", "nope", 1)]
    [InlineData("nope", "dailyCap", 2)]
    public async Task SetPolicyRejectsBadValues(string id, string key, object value)
    {
        model.State.SectionsChosen = ["economy"];
        var before = model.Policy("economy");
        await Assert.ThrowsAnyAsync<Exception>(() => Do("setPolicy", new { id, key, value }));
        Assert.Equal(before, model.Policy("economy"));
        Assert.False(model.State.SectionPolicy.ContainsKey("nope"));
    }

    [Fact]
    public async Task SetsLimits()
    {
        await SetValue("totalDailyCap", 30);
        await SetValue("krThreshold", 1);
        await SetValue("intlThreshold", 10);
        await SetValue("bigThreshold", 2);
        var st = model.State.Settings;
        Assert.Equal((30, 1, 10, 2), (st.TotalDailyCap, st.KrThreshold, st.IntlThreshold, st.BigThreshold));
        Assert.Equal(30, st.Limits.TotalCap);
        var limits = Json(page.View())["sections"]!["limits"]!;
        Assert.Equal("하루 전체 물방울 30번까지", limits[0]!["label"]!.GetValue<string>());
        Assert.Equal((1, 30), (limits[0]!["min"]!.GetValue<int>(), limits[0]!["max"]!.GetValue<int>()));
    }

    [Theory]
    [InlineData("totalDailyCap", 0)]
    [InlineData("totalDailyCap", 31)]
    [InlineData("krThreshold", 0)]
    [InlineData("intlThreshold", 11)]
    [InlineData("bigThreshold", 1)]
    [InlineData("bigThreshold", 21)]
    public async Task LimitsRejectOutOfRange(string key, int value)
    {
        var before = model.State.Settings.Copy();
        await Assert.ThrowsAnyAsync<Exception>(() => SetValue(key, value));
        var st = model.State.Settings;
        Assert.Equal((before.TotalDailyCap, before.KrThreshold, before.IntlThreshold, before.BigThreshold),
            (st.TotalDailyCap, st.KrThreshold, st.IntlThreshold, st.BigThreshold));
    }

    [Fact]
    public async Task UnhidesSource()
    {
        var src = Resources.Config.Sources[0];
        model.HideSource(src.Id);
        model.State.HiddenSources.Add("gone-source"); // 이제 목록에 없는 출처는 id 로 보임
        var hidden = Json(page.View())["sections"]!["hidden"]!;
        Assert.Equal([src.Id, "gone-source"], Strs(hidden, "id"));
        Assert.Equal(Sections.Meta.GetValueOrDefault(src.Id)?.Name ?? src.Name, hidden[0]!["name"]!.GetValue<string>());
        Assert.Equal("gone-source", hidden[1]!["name"]!.GetValue<string>());

        await Do("unhide", new { id = src.Id });
        Assert.Equal(["gone-source"], model.State.HiddenSources);
        await Assert.ThrowsAnyAsync<Exception>(() => Do("unhide", new { id = src.Id })); // 숨기지 않은 출처
    }

    [Fact]
    public async Task ReopensOnboarding()
    {
        await Do("onboarding", new { });
        Assert.Equal(1, platform.Onboarding);
    }
}

// 번역 방식 고르기(W4): 설정 › 일반 › 번역
public class SettingsTranslateEngineTests : IDisposable
{
    private readonly TempDir tmp = new();
    private readonly Database db;
    private readonly AppModel model;
    private readonly SettingsPage page;

    public SettingsTranslateEngineTests()
    {
        db = new Database(System.IO.Path.Combine(tmp.Path, "magazine.sqlite"));
        model = new AppModel(new FakeUi(), new Magazine(db), new AppState(), persist: false) { ShowAllSourcesForTests = true };
        page = new SettingsPage(model, new MiniPlatform());
    }

    public void Dispose() { model.Stop(); db.Dispose(); tmp.Dispose(); }

    private Task<object?> Do(string cmd, object args) =>
        page.Handle(cmd, (JsonObject)JsonSerializer.SerializeToNode(args, global::Dropcap.Core.Json.Options)!);
    private async Task<JsonNode> General() => JsonSerializer.SerializeToNode(await Do("view", new { }), global::Dropcap.Core.Json.Options)!["general"]!;

    [Fact]
    public async Task ChooseEngineAndPrivacyNote()
    {
        var g = await General();
        Assert.Equal("auto", (string)g["translateEngine"]!);
        Assert.Equal(["auto", "google", "off"], g["translateEngines"]!.AsArray().Select(n => (string)n!["id"]!));
        Assert.Contains("Google 번역으로 본문 문단이 전송", (string)g["translationNote"]!);
        await Do("set", new { key = "translateEngine", value = "off" });
        Assert.Equal("off", model.State.Settings.TranslateEngine);
        await Assert.ThrowsAnyAsync<ArgumentException>(() => Do("set", new { key = "translateEngine", value = "apple" })); // 이 PC 에서 고를 수 없음
        Assert.Equal("off", model.State.Settings.TranslateEngine);
        // 앱 번역기가 이 설정을 따른다
        Assert.Equal("Hello world", await Translator.Shared.TranslateAsync("Hello world"));
    }

    [Fact]
    public async Task AppleFromMacIsShownAndKept()
    {
        model.Update(s => s.TranslateEngine = "apple");
        var g = await General();
        Assert.Equal("apple", (string)g["translateEngine"]!);
        Assert.Contains("apple", g["translateEngines"]!.AsArray().Select(n => (string)n!["id"]!));
    }
}
