using System.Net;
using System.Net.Http.Headers;
using Dropcap.Core;
using Dropcap.Ui;

namespace Dropcap.Core.Tests;

// 맥 mac/Tests/DropcapTests/Extras2Tests.swift 를 옮긴 것(남은 개선 2차 — mac/EXTRAS.md 2차):
// 받는 크기 상한(S-12) · 번역 엔진 표시·긴 문단(T-08) · 지켜볼 낱말(N-27) · Ollama 고르기(클라우드 모델 제외)

public class FetchLimitTests
{
    // 읽힌 만큼 세는 흐름(끝없이 흘려 보내는 서버 흉내)
    private sealed class Endless(long total) : Stream
    {
        public long Served { get; private set; }
        public override int Read(byte[] buffer, int offset, int count)
        {
            var n = (int)Math.Min(count, total - Served);
            if (n <= 0) return 0;
            Array.Fill(buffer, (byte)'a', offset, n);
            Served += n;
            return n;
        }
        public override bool CanRead => true; public override bool CanSeek => false; public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException(); public override long Position { get => Served; set => throw new NotSupportedException(); }
        public override void Flush() { } public override long Seek(long o, SeekOrigin s) => throw new NotSupportedException();
        public override void SetLength(long v) => throw new NotSupportedException(); public override void Write(byte[] b, int o, int c) => throw new NotSupportedException();
    }

    private sealed class Boom : Stream   // 한 바이트라도 읽으면 실패
    {
        public override int Read(byte[] buffer, int offset, int count) => throw new InvalidOperationException("본문을 읽으면 안 됨");
        public override bool CanRead => true; public override bool CanSeek => false; public override bool CanWrite => false;
        public override long Length => 0; public override long Position { get => 0; set { } }
        public override void Flush() { } public override long Seek(long o, SeekOrigin s) => 0;
        public override void SetLength(long v) { } public override void Write(byte[] b, int o, int c) { }
    }

    [Fact]
    public async Task SmallBodyPasses()
    {
        var body = await SafeHttp.ReadCappedAsync(new ByteArrayContent(new byte[1024]), FetchLimit.Feed, default);
        Assert.Equal(1024, body.Length);
    }

    [Fact]
    public async Task DeclaredLengthOverLimitIsRefusedBeforeBody()
    {
        var c = new StreamContent(new Boom());
        c.Headers.ContentLength = 11L << 20;   // 11MB 를 밝힌 응답
        var e = await Assert.ThrowsAsync<TooLargeException>(() => SafeHttp.ReadCappedAsync(c, FetchLimit.Feed, default));
        Assert.Equal("응답이 너무 커서 받다가 멈춤(10MB 넘음)", e.Message);
    }

    [Fact]
    public async Task UndeclaredStreamIsCutAtLimit()
    {
        var s = new Endless(60L << 20);   // 길이를 밝히지 않고 60MB 를 흘림
        await Assert.ThrowsAsync<TooLargeException>(() => SafeHttp.ReadCappedAsync(new StreamContent(s), FetchLimit.Feed, default));
        Assert.True(s.Served < 12L << 20, $"{s.Served >> 20}MB 를 받음");   // 상한 근처에서 멈춤
    }

    [Fact]
    public async Task PageAndImageLimits()
    {
        var page = new byte[3 << 20];
        await Assert.ThrowsAsync<TooLargeException>(() => SafeHttp.ReadCappedAsync(new ByteArrayContent(page), FetchLimit.Page, default));
        Assert.Equal(page.Length, (await SafeHttp.ReadCappedAsync(new ByteArrayContent(page), FetchLimit.Feed, default)).Length); // 피드 상한에는 통과
        await Assert.ThrowsAsync<TooLargeException>(() => SafeHttp.ReadCappedAsync(new ByteArrayContent(new byte[9 << 20]), FetchLimit.Image, default));
        Assert.Equal(10L << 20, FetchLimit.Feed);
        Assert.Equal(2L << 20, FetchLimit.Page);
        Assert.Equal(8L << 20, FetchLimit.Image);
        Assert.Equal(FetchLimit.Image, ImageLoader.MaxBytes);
    }
}

public class TranslatorChunkTests
{
    [Fact]
    public void SentenceChunksKeepTextAndLimit()
    {
        var sentence = "This is a fairly ordinary sentence about markets and chips. ";
        var text = string.Concat(Enumerable.Repeat(sentence, 200));   // 약 12,000자
        var chunks = Translator.SentenceChunks(text, 4500);
        Assert.True(chunks.Count >= 3);
        Assert.All(chunks, c => Assert.True(c.Length <= 4500));
        Assert.Equal(text, string.Concat(chunks));                      // 이어 붙이면 원문 그대로
        Assert.All(chunks.SkipLast(1), c => Assert.EndsWith(". ", c));   // 문장 끝에서 나눔
    }

    [Fact]
    public void NoSentenceEndCutsEvery4500()
    {
        var text = new string('x', 10_000);
        var chunks = Translator.SentenceChunks(text, 4500);
        Assert.Equal([4500, 4500, 1000], chunks.Select(c => c.Length));
        Assert.Equal([text[..100]], Translator.SentenceChunks(text[..100], 4500));
    }

    [Fact]
    public async Task LongParagraphIsSentInPiecesAndEngineReported()
    {
        var sent = new List<int>();
        var t = new Translator { Backend = (text, _) => { sent.Add(text.Length); return Task.FromResult<string?>("번역"); } };
        var longP = string.Concat(Enumerable.Repeat("Sentence number one is here. ", 400));   // 약 11,600자
        var (outs, engine) = await t.TranslateManyReportingAsync([longP]);
        Assert.True(sent.Count >= 3 && sent.All(n => n <= 4500));   // 뒤가 잘리지 않게 나눠 보냄
        Assert.StartsWith("번역 번역 번역", outs[0]);
        Assert.Equal(Translator.EngineGoogle, engine);
        var (_, again) = await t.TranslateManyReportingAsync([longP]);   // 캐시로 끝나도 그 엔진
        Assert.Equal(Translator.EngineGoogle, again);
        var (_, none) = await t.TranslateManyReportingAsync(["이미 한국어 문장입니다"]);
        Assert.Equal(Translator.EngineNone, none);                        // 번역할 것이 없으면 '번역 안 함'
    }
}

public class WatchWordsTests : IDisposable
{
    private readonly TempDir tmp = new();
    private readonly Database db;
    private readonly FakeUi ui = new();
    private readonly AppModel model;
    private DateTimeOffset now = new(DateTime.Today.AddHours(9).AddMinutes(30));

    public WatchWordsTests()
    {
        db = new Database(Path.Combine(tmp.Path, "magazine.sqlite"));
        model = new AppModel(ui, new Magazine(db), new AppState(), persist: false) { ShowAllSourcesForTests = true, Now = () => now };
    }

    public void Dispose() { db.Dispose(); tmp.Dispose(); }

    [Fact]
    public void BoundariesAndKoreanPartialMatch()
    {
        Assert.True(WatchWords.Matches("Apple", "Apple unveils new chip"));
        Assert.False(WatchWords.Matches("Apple", "Pineapple prices rise"));
        Assert.True(WatchWords.Matches("GPT-6", "OpenAI ships GPT-6 today"));
        Assert.False(WatchWords.Matches("GPT-6", "GPT-60 rumor"));
        Assert.True(WatchWords.Matches("엔비디아", "엔비디아가 실적을 발표했다"));   // 조사
        Assert.True(WatchWords.Matches("AI 기본법", "국회, AI 기본법 시행령 의결"));
        Assert.True(WatchWords.Matches("c++", "Why C++ still matters"));          // 특수 문자도 그대로
        Assert.Equal(["삼성전자", "Apple"], WatchWords.Normalized([" 삼성전자 ", "", "Apple", "apple"]));
    }

    [Fact]
    public void FirstWordInOrderAndDigest()
    {
        var a = Extras.News("1", "a", title: "Apple and Nvidia team up", date: now.AddHours(-1));
        var b = Extras.News("2", "b", title: "Nvidia earnings beat", date: now.AddHours(-2));
        var c = Extras.News("3", "c", title: "Weather today", date: now);
        Assert.Equal("Nvidia", WatchWords.Match(a, ["Nvidia", "Apple"]));
        var d = WatchWords.Digest([b, a, c, a], ["Apple", "Nvidia", "Tesla"]);
        Assert.Equal(["Apple", "Nvidia"], d.Select(x => x.Word));                 // 걸린 것 없는 낱말은 뺌
        Assert.Equal(["a|1", "b|2"], d[1].Items.Select(i => i.Key));             // 같은 기사는 한 번, 최신 순
    }

    [Fact]
    public void PolicyNotifiesRegardlessOfSectionUntilCap()
    {
        var l = new PolicyLimits();
        NotifyPolicy.Input In(int total, int kr = 0) => new() { Chosen = false, Policy = new SectionPolicy { Mode = NotifyMode.Magazine }, Watched = true, SentTotal = total, Coverage = new Coverage(kr, 0) };
        Assert.Equal(NotifyDecision.Drop, NotifyPolicy.Decide(In(0), l));        // 고르지 않은 분야·매거진만이어도
        Assert.Equal(NotifyDecision.Pool, NotifyPolicy.Decide(In(l.TotalCap), l)); // 전체 상한이 차면 고임
        Assert.Equal(NotifyDecision.Drop, NotifyPolicy.Decide(In(l.TotalCap, kr: l.BigThreshold), l)); // 국내 8곳 이상이면 상한 무시
    }

    [Fact]
    public void KeywordsMarkWatchAndStarWins()
    {
        model.Update(s => { s.WatchKeywords = ["Nvidia"]; s.MustKeywords = ["earnings"]; });
        var o = model.ApplyKeywords([Extras.News("1", "a", title: "Nvidia ships chips"), Extras.News("2", "a", title: "Nvidia earnings")]);
        Assert.Equal("Nvidia", o[0].Watch);
        var v = Dropcap.Ui.ItemView.From(o[1], null);
        Assert.True(v.Important);
        Assert.Null(v.Watch);                                                    // ★ 와 겹치면 ★ 만
        Assert.Equal("Nvidia", Dropcap.Ui.ItemView.From(o[0], null).Watch);
    }

    [Fact]
    public void WatchedStoryDropsEvenWhenSectionNotChosen()
    {
        model.ChooseSections(["economy"]);
        model.Update(s => s.WatchKeywords = ["Nvidia"]);
        var it = model.ApplyKeywords([Extras.News("w", "verge", title: "Nvidia unveils a new GPU")]);
        var drops = model.Decide(it, it, quiet: false);
        Assert.Single(drops);
        Assert.Empty(model.Decide(it, it, quiet: false));                        // 같은 이야기는 한 번
    }

    [Fact]
    public void DailyDigestOnceInWindowAndNotWhenHushed()
    {
        model.Update(s => s.WatchKeywords = ["Nvidia", "Apple", "Tesla", "Intel"]);
        model.Magazine.Ingest([
            Extras.News("1", "a", title: "Nvidia one", date: now.AddHours(-1)), Extras.News("2", "b", title: "Nvidia two", date: now.AddHours(-2)),
            Extras.News("3", "c", title: "Apple three", date: now.AddHours(-3)), Extras.News("4", "d", title: "Tesla four", date: now.AddHours(-3)),
            Extras.News("5", "e", title: "Intel five", date: now.AddHours(-4)), Extras.News("6", "hidden", title: "Nvidia hidden", date: now.AddHours(-1)),
        ], enrich: false);
        model.State.HiddenSources.Add("hidden");
        model.Focus.Override = new FocusMonitor.Fixed(FocusReason.Fullscreen);
        model.DeliverWatchDigest();
        Assert.Empty(ui.Watches);                                                // 회의 중이면 끝난 뒤로
        model.Focus.Override = new FocusMonitor.Fixed(null);
        model.DeliverWatchDigest();
        Assert.Equal([("Nvidia", 2), ("Apple", 1), ("Tesla", 1)], ui.Watches);   // 세 개까지, 숨긴 출처 뺌
        model.DeliverWatchDigest();
        Assert.Equal(3, ui.Watches.Count);                                       // 하루 한 번
        now = now.AddDays(1).Date.AddHours(13);
        model.DeliverWatchDigest();
        Assert.Equal(3, ui.Watches.Count);                                       // 정오가 지나면 그날은 건너뜀
    }

    [Fact]
    public void OldSettingsHaveNoWatchWords()
    {
        Assert.Empty(AppState.FromJson("""{"settings":{"mustKeywords":["a"]}}""").Settings.WatchKeywords);
        var s = new AppState();
        s.Settings.WatchKeywords = ["엔비디아"];
        Assert.Equal(["엔비디아"], AppState.FromJson(s.ToJson()).Settings.WatchKeywords);
        Assert.Equal("오늘 엔비디아 소식 3건", Strings.Watch("엔비디아", 3));
    }
}

public class OllamaModelTests
{
    [Fact]
    public void CloudAndEmbeddingModelsAreNotOnDevice()
    {
        Assert.False(Summarizer.LocalTextModel("gpt-oss:120b-cloud"));          // 글을 바깥 서버로 보내는 모델
        Assert.False(Summarizer.LocalTextModel("nomic-embed-text:latest"));
        Assert.True(Summarizer.LocalTextModel("qwen2.5:7b"));
        Assert.Equal("qwen2.5:7b", Summarizer.PickModel(["gpt-oss:120b-cloud", "nomic-embed-text", "qwen2.5:7b"], null));
        Assert.Null(Summarizer.PickModel(["gpt-oss:20b-cloud"], null));
        Assert.Null(Summarizer.PickModel(["gpt-oss:20b-cloud", "qwen2.5:7b"], "gpt-oss"));   // 정해도 클라우드는 안 씀
        Assert.Equal("qwen2.5:7b", Summarizer.PickModel(["qwen2.5:7b", "qwen2.5-coder:7b"], "qwen2.5"));
    }
}

// 설정 '일반 › 내 기록'(P-08): 내보내기 → 같은 파일 가져오기 → 되돌리기
public class SettingsBackupTests : IDisposable
{
    private sealed class Platform : IPlatform
    {
        public string? Saved;
        public void OpenMagazine(string? page = null) { }
        public void OpenSettings(string? tab = null) { }
        public void OpenOnboarding() { }
        public void OpenReader(NewsItem item) { }
        public void CloseWindow(string page) { }
        public void Quit() { }
        public void CopyText(string text) { }
        public Task<bool> SaveTextFile(string suggestedName, string text) => Task.FromResult(true);
        public void Share(NewsItem item) { }
        public void Speak(string text, string language) { }
        public void StopSpeaking() { }
        public bool Speaking => false;
        public bool LaunchAtLogin { get; set; }
        public bool ReduceMotion => false;
        public void ApplyFont() { }
        public Task<bool> SaveJsonFile(string suggestedName, string text) { Saved = text; return Task.FromResult(true); }
        public Task<string?> OpenJsonFile() => Task.FromResult(Saved);
    }

    private readonly TempDir tmp = new();
    private readonly Database db;

    public SettingsBackupTests() => db = new Database(Path.Combine(tmp.Path, "magazine.sqlite"));
    public void Dispose() { db.Dispose(); tmp.Dispose(); }

    private static System.Text.Json.Nodes.JsonObject A(object o) =>
        (System.Text.Json.Nodes.JsonNode.Parse(System.Text.Json.JsonSerializer.Serialize(o)) as System.Text.Json.Nodes.JsonObject)!;
    private static string Msg(object? o) => System.Text.Json.Nodes.JsonNode.Parse(System.Text.Json.JsonSerializer.Serialize(o, Json.Options))!["message"]!.GetValue<string>();

    [Fact]
    public async Task ExportImportUndoFromSettings()
    {
        var model = new AppModel(new FakeUi(), new Magazine(db), new AppState(), persist: false) { ShowAllSourcesForTests = true };
        var p = new Platform();
        var page = new SettingsPage(model, p, new Scrapbook(db));
        model.Update(s => s.WatchKeywords = ["엔비디아"]);
        Assert.Equal("내보냈습니다", Msg(await page.Handle("exportBackup", A(new { }))));
        Assert.Contains("\"format\" : \"dropcap-backup\"", p.Saved);
        Assert.Contains("새로 더할 것이 없었습니다", Msg(await page.Handle("importBackup", A(new { }))));
        Assert.True(Backup.CanUndo);
        Assert.Equal("가져오기 전으로 되돌렸습니다", Msg(await page.Handle("undoImport", A(new { }))));
        p.Saved = """{"hello":1}""";
        Assert.Equal("가져오지 못했습니다: Dropcap 기록 파일이 아닙니다", Msg(await page.Handle("importBackup", A(new { }))));
    }
}

// 보안 검토: 가져온 기록 파일은 설정 화면의 검사를 건너뛰지 못한다(범위 밖 수치·위험한 출처·정규식)
public class BackupSanitizeTests
{
    [Fact]
    public void HostileFileIsClampedAndFiltered()
    {
        var json = """
        {"format":"dropcap-backup","version":1,
         "settings":{"intervalMinutes":0,"quietStart":99,"digestHour":-3,"totalDailyCap":100000,"bigThreshold":0,
                     "mustKeywords":["","ok","OK","%%LONG%%"]},
         "sectionPolicy":{"economy":{"mode":"bundle","bundleHour":99,"dailyCap":-5},"nope":{"mode":"instant"}},
         "sectionsChosen":["economy","nope"],
         "customSources":[
           {"id":"custom-a","name":"A","tier":"press","type":"sitemap","url":"https://a.example/sitemap.xml","match":"(a+)+$","color":"red","aiOnly":true,"defaultOn":true},
           {"id":"custom-b","name":"B","tier":"press","type":"feed","url":"file:///C:/secret.xml","color":"#000000","aiOnly":false,"defaultOn":true},
           {"id":"custom-c","name":"C","tier":"press","type":"feed","url":"http://127.0.0.1/feed","color":"#000000","aiOnly":false,"defaultOn":true},
           {"id":"openai","name":"spoof","tier":"lab","type":"feed","url":"https://evil.example/feed","color":"#000000","aiOnly":false,"defaultOn":true}]}
        """.Replace("%%LONG%%", new string('x', 500));
        var b = BackupFile.FromJson((System.Text.Json.Nodes.JsonNode.Parse(json) as System.Text.Json.Nodes.JsonObject)!);
        Assert.Equal(5, b.Settings.IntervalMinutes);
        Assert.Equal(23, b.Settings.QuietStart);
        Assert.Equal(5, b.Settings.DigestHour);
        Assert.Equal(30, b.Settings.TotalDailyCap);
        Assert.Equal(2, b.Settings.BigThreshold);
        Assert.Equal(["ok"], b.Settings.MustKeywords);                     // 빈 것·대소문자만 다른 것·너무 긴 것 뺌
        Assert.Equal(["economy"], b.SectionPolicy.Keys);                    // 모르는 분야 뺌
        Assert.Equal(23, b.SectionPolicy["economy"].BundleHour);
        Assert.Equal(1, b.SectionPolicy["economy"].DailyCap);
        Assert.Equal(["economy"], b.SectionsChosen);
        var a = Assert.Single(b.CustomSources);                            // file://·내부망·기본 출처 id 흉내는 뺌
        Assert.Equal("feed", a.Type);
        Assert.Null(a.Match);                                              // 정규식은 가져오지 않음
        Assert.False(a.AiOnly);
        Assert.Equal("#3B82F6", a.Color);
    }
}
