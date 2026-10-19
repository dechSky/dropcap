using System.Diagnostics;
using Dropcap.Ui;
using Microsoft.Data.Sqlite;
using SkiaSharp;

namespace Dropcap.Core.Tests;

// 안정화(맥 StabilityTests 와 같은 규칙). 바깥 서버·창 없이 돈다.
public class StabilityTests : IDisposable
{
    private readonly TempDir tmp = new();
    private readonly List<Database> dbs = new();
    private readonly DateTimeOffset now = DateTimeOffset.Now;

    public void Dispose()
    {
        foreach (var d in dbs) d.Dispose();
        tmp.Dispose();
    }

    private Database Db(string name = "magazine.sqlite", int busyTimeoutMs = 3000)
    {
        var d = new Database(Path.Combine(tmp.Path, name), busyTimeoutMs);
        dbs.Add(d);
        return d;
    }

    private NewsItem It(string id, string title, string src, double minutesAgo, string? image = null) => new()
    {
        Id = id, Title = title, Link = "https://x.com/" + id, Date = now.AddMinutes(-minutesAgo), SourceId = src, SourceName = src.ToUpperInvariant(), Image = image,
    };

    private static byte[] Jpeg(int w, int h, SKColor color)
    {
        using var bmp = new SKBitmap(w, h);
        bmp.Erase(color);
        using var img = SKImage.FromBitmap(bmp);
        using var enc = img.Encode(SKEncodedImageFormat.Jpeg, 80);
        return enc.ToArray();
    }

    // MARK: 사진 메모리
    // 그리기용 사진 기억은 풀린 크기(바이트)로 묶는다 — 장 수(160)만으로는 큰 사진 수십 장이 수백 MB 를 붙들었다
    [Fact]
    public async Task ImageMemoryCacheIsBoundedInBytes()
    {
        var loader = new ImageLoader(Path.Combine(tmp.Path, "images"));
        var jpg = Jpeg(1400, 1000, SKColors.SteelBlue);   // 풀면 5.6MB
        for (var i = 0; i < 40; i++)
        {
            var url = $"https://img.example.com/p{i}.jpg";
            File.WriteAllBytes(loader.FileFor(url), jpg);
            Assert.NotNull(await loader.ImageAsync(url));
        }
        Assert.True(loader.MemoryBytes <= ImageLoader.MemoryLimitBytes, $"{loader.MemoryBytes >> 20}MB");
        Assert.NotNull(loader.Cached("https://img.example.com/p39.jpg"));   // 최근 것은 남고
        Assert.Null(loader.Cached("https://img.example.com/p0.jpg"));       // 오래 안 쓴 것부터 버림
    }

    // 같은 주소를 동시에 부르면 하나만 담고 진 쪽 그림은 버린다(예전엔 진 그림을 Dispose 하지 않고 돌려줘 기억 밖에서 떠돌았다)
    [Fact]
    public async Task RacingLoadsShareOneImage()
    {
        var loader = new ImageLoader(Path.Combine(tmp.Path, "images"));
        var url = "https://img.example.com/race.jpg";
        File.WriteAllBytes(loader.FileFor(url), Jpeg(400, 300, SKColors.Coral));
        var got = await Task.WhenAll(Enumerable.Range(0, 8).Select(_ => loader.ImageAsync(url)));
        var kept = loader.Cached(url);
        Assert.NotNull(kept);
        Assert.All(got, g => Assert.Same(kept, g));
    }

    // 큰 JPEG 는 원본 전체를 풀지 않고 줄인 크기로 푼다(40MP 까지 받으니 한 장에 160MB 를 풀던 것)
    [Fact]
    public void ShrinkDecodesLargeJpegScaledDown()
    {
        var big = Jpeg(5600, 4000, SKColors.DarkOliveGreen);
        var jpg = ImageLoader.Shrink(big);
        Assert.NotNull(jpg);
        using var codec = SKCodec.Create(new MemoryStream(jpg!));
        Assert.Equal(1400, codec.Info.Width);
        Assert.Equal(1000, codec.Info.Height);
        Assert.True(ImageLoader.LastDecode.Width < 5600, $"풀린 크기 {ImageLoader.LastDecode}");
        Assert.True(ImageLoader.LastDecode.Width >= 1400);   // 줄인 결과보다 작게 풀지는 않는다(흐려지지 않게)
    }

    // MARK: 번역
    // 대답하지 않는 번역 서버: 요청마다 상한에 걸려 원문 그대로(확인이 번역을 기다리다 멈추지 않게)
    [Fact]
    public async Task SilentTranslateServerFallsBackToOriginal()
    {
        var t = new Translator { RequestDeadline = TimeSpan.FromMilliseconds(200), Backend = (_, _) => new TaskCompletionSource<string?>().Task };
        var task = t.TranslateManyAsync(["OpenAI releases a new model", "It is fast."]);
        var done = await Task.WhenAny(task, Task.Delay(TimeSpan.FromSeconds(5)));
        Assert.Same(task, done);
        Assert.Equal(["OpenAI releases a new model", "It is fast."], await task);
    }

    // 묶음이 상한에 걸리면 문단마다 다시 보내며 상한을 문단 수만큼 기다리지 않는다(1분 동안 쉬기)
    [Fact]
    public async Task SilentServerDoesNotMultiplyWaits()
    {
        var calls = 0;
        var t = new Translator
        {
            RequestDeadline = TimeSpan.FromMilliseconds(200),
            Backend = (_, _) => { Interlocked.Increment(ref calls); return new TaskCompletionSource<string?>().Task; },
        };
        var paras = Enumerable.Range(0, 12).Select(i => $"Paragraph number {i} about models").ToList();
        var sw = Stopwatch.StartNew();
        var task = t.TranslateManyAsync(paras);
        var done = await Task.WhenAny(task, Task.Delay(TimeSpan.FromSeconds(10)));
        Assert.Same(task, done);
        Assert.Equal(paras, await task);
        Assert.True(sw.Elapsed < TimeSpan.FromSeconds(1.5), $"{sw.Elapsed.TotalSeconds:0.0}초");
        Assert.True(calls <= Translator.ParallelBatches, $"요청 {calls}번");
        // 쉬는 동안은 아예 보내지 않음
        var before = calls;
        Assert.Equal("Another headline here", await t.TranslateAsync("Another headline here"));
        Assert.Equal(before, calls);
    }

    // MARK: 잠시 끄기
    // 시계가 앞서 있던 때 켠 잠시 끄기(이틀보다 먼 끝)는 풀린 것으로 보고, 1분 점검이 지운다
    [Fact]
    public void SnoozeFromFutureClockIsReleased()
    {
        var db = Db();
        var model = new AppModel(new FakeUi(), new Magazine(db), new AppState(), persist: false) { Now = () => now };
        model.Snooze(now.AddDays(10));
        Assert.False(model.IsSnoozed);
        model.MinuteTick();
        Assert.Null(model.State.SnoozeUntil);
        // 보통의 잠시 끄기(내일 아침 8시까지 — 32시간 안)는 그대로
        model.Snooze(AppModel.TomorrowMorning(now));
        Assert.True(model.IsSnoozed);
        model.MinuteTick();
        Assert.NotNull(model.State.SnoozeUntil);
    }

    // MARK: 스토리 목록
    private void SeedStories(Magazine mag, int n)
    {
        var items = new List<NewsItem>();
        for (var k = 0; k < n; k++)
        {
            var title = $"Quokka{k} acquires Wombat{k} in record Platypus{k} deal";
            items.Add(It($"a{k}", title, "srca", 30 + k));
            items.Add(It($"b{k}", title, "srcb", 20 + k));
        }
        mag.Ingest(items, enrich: false);
    }

    // 스토리 목록 전체를 문장 몇 번으로(스토리마다 두 번씩 묻지 않게)
    [Fact]
    public void StoryListAsksDatabaseOnce()
    {
        var db = Db();
        var mag = new Magazine(db);
        SeedStories(mag, 30);
        var before = db.Statements;
        var stories = mag.Stories();
        Assert.Equal(30, stories.Count);
        Assert.True(db.Statements - before <= 3, $"문장 {db.Statements - before}번");
    }

    // 보도가 아주 많은 스토리: 수는 전부 세되 카드에는 견본만(출처마다 첫 보도 + 최근 것) 꺼낸다(맥 bigStoryCardTakesSample)
    [Fact]
    public void BigStoryCardTakesSample()
    {
        var db = Db();
        var mag = new Magazine(db);
        db.SaveCluster(new Database.Cluster("big", "big story", new(), now.AddHours(-2), now, 600));
        for (var i = 0; i < 600; i++)
            db.Upsert(It($"b{i}", $"big story {i}", i < 3 ? $"src{i}" : "src0", 120 - i / 10.0), "big"); // 출처 셋, 거의 다 src0
        var c = Assert.Single(mag.StoryCards(new SourceFilter(), now));
        Assert.Equal(600, c.Cluster.Size);
        Assert.True(c.Items.Count <= Database.StorySample + 3, $"견본 {c.Items.Count}건");
        Assert.Equal(3, c.Items.Select(i => i.SourceId).Distinct().Count());   // 출처 줄은 그대로
        Assert.Equal("big story 0", c.Items[0].Title);                        // 첫 보도
        Assert.Contains(c.Items, i => i.Title == "big story 599");            // 최근 보도
        // 숨긴 출처는 세지 않는다
        var h = Assert.Single(mag.StoryCards(new SourceFilter { Hidden = new HashSet<string> { "src0" } }, now));
        Assert.Equal(2, h.Cluster.Size);
        Assert.Equal(2, h.Items.Count);
    }

    // 스토리 화면도: 카드에 보도를 넘겨 카드가 DB 를 다시 묻지 않는다
    [Fact]
    public async Task StoryPageAsksDatabaseOnce()
    {
        var db = Db();
        var mag = new Magazine(db);
        var model = new AppModel(new FakeUi(), mag, new AppState(), persist: false) { ShowAllSourcesForTests = true };
        var page = new MagazinePage(model, mag, new Scrapbook(db), null!, new Bridge()) { LoadPhotos = _ => { }, PhotoUrl = _ => null };
        SeedStories(mag, 30);
        model.MarkStorySeen(mag.Stories()[0].Id, 1);
        var before = db.Statements;
        var view = await page.StoriesData();
        Assert.Equal(30, view.Live.Count + view.Past.Count);
        Assert.True(db.Statements - before <= 3, $"문장 {db.Statements - before}번");
        Assert.Contains(view.Live, c => c.Fresh == 1);   // 본 뒤 붙은 보도 수는 그대로
    }

    // MARK: DB 쓰기 실패
    private static SqliteConnection Lock(string file)
    {
        var c = new SqliteConnection($"Data Source={file};Pooling=False");
        c.Open();
        using var cmd = c.CreateCommand();
        cmd.CommandText = "BEGIN EXCLUSIVE";
        cmd.ExecuteNonQuery();
        return c;
    }

    // DB 가 오래 잠겨 못 넣은 글은 버리지 않고 다음 받아 넣기 때 먼저 넣는다(상태에는 이미 '본 글'이라 피드에서 다시 오지 않음)
    [Fact]
    public void FailedIngestIsRetried()
    {
        var db = Db(busyTimeoutMs: 200);
        var mag = new Magazine(db);
        var items = Enumerable.Range(0, 5).Select(i => It($"r{i}", $"Lonely headline number {i} about turtles", "src", i)).ToList();
        var sw = Stopwatch.StartNew();
        using (Lock(db.FilePath)) mag.Ingest(items, enrich: false);   // 끊기지 않음
        Assert.True(sw.Elapsed < TimeSpan.FromSeconds(3), $"{sw.Elapsed.TotalSeconds:0.0}초 — 한 번 실패하면 나머지는 바로 미룸");
        Assert.Equal(5, mag.RetryCount);
        mag.Ingest([], enrich: false);
        Assert.Equal(0, mag.RetryCount);
        Assert.Equal(5, db.ItemCount);
    }

    // 잠깐 잠긴 것은 기다렸다가 넣는다
    [Fact]
    public async Task ShortLockIsWaitedOut()
    {
        var db = Db(busyTimeoutMs: 3000);
        var mag = new Magazine(db);
        var locker = Lock(db.FilePath);
        var release = Task.Run(async () => { await Task.Delay(400); locker.Dispose(); });
        mag.Ingest([It("w1", "Short lock headline about penguins", "src", 1)], enrich: false);
        await release;
        Assert.Equal(0, mag.RetryCount);
        Assert.Equal(1, db.ItemCount);
    }

    // 다시 넣을 목록은 3000건까지(오래된 것부터 버림)
    [Fact]
    public void RetryListIsCapped()
    {
        var db = Db(busyTimeoutMs: 50);
        var mag = new Magazine(db);
        var items = Enumerable.Range(0, Magazine.RetryLimit + 100).Select(i => It($"c{i}", $"Capped item {i}", "src", i)).ToList();
        using (Lock(db.FilePath)) mag.Ingest(items, enrich: false);
        Assert.Equal(Magazine.RetryLimit, mag.RetryCount);
    }

    // 다시 넣을 목록은 자료 폴더 파일에 남아, 앱을 껐다 켜도(새 인스턴스·같은 파일) 다시 넣는다. 다 넣으면 파일을 지운다
    [Fact]
    public void RetryOutlivesRestart()
    {
        var db = Db(busyTimeoutMs: 50);
        var file = Path.Combine(tmp.Path, Magazine.RetryFileName);
        var items = Enumerable.Range(0, 3).Select(i => It($"s{i}", $"Restart survivor {i} about otters", "src", i)).ToList();
        using (Lock(db.FilePath)) new Magazine(db, retryFile: file).Ingest(items, enrich: false);
        Assert.True(File.Exists(file));
        var again = new Magazine(db, retryFile: file);
        Assert.Equal(3, again.RetryCount);
        again.Ingest([], enrich: false);
        Assert.Equal(3, db.ItemCount);
        Assert.False(File.Exists(file));
        File.WriteAllText(file, "{깨진");   // 깨진 파일은 빈 것으로
        Assert.Equal(0, new Magazine(db, retryFile: file).RetryCount);
    }

    // MARK: 분야 사진
    // 분야 사진은 최근 기록을 한 번 읽어 분야마다 나눠 쓴다(분야마다 3000건씩 읽지 않게)
    [Fact]
    public async Task SectionPhotosReadRecordOnce()
    {
        var reads = 0;
        var picked = new List<int>();
        var photos = new SectionPhotos
        {
            Recent = () => { Interlocked.Increment(ref reads); return [It("p1", "프로야구 홈런 기록", "s", 1, "https://x.com/1.jpg")]; },
            Pick = items => { lock (picked) picked.Add(items.Count()); return Task.FromResult<string?>(null); },
            Feed = _ => Task.FromResult(new List<NewsItem>()),
        };
        var ids = Sections.All.Select(s => s.Id).ToList();
        photos.Load(ids);
        for (var i = 0; i < 100 && picked.Count < ids.Count * 2; i++) await Task.Delay(20);
        Assert.Equal(ids.Count * 2, picked.Count);
        Assert.Equal(1, reads);
    }

    // 기사 분류(Category)는 한 번만 잰다. 제목이 바뀐 사본(with)은 다시 잰다
    [Fact]
    public void CategoryIsComputedOnce()
    {
        var it = It("k1", "OpenAI releases new model weights", "src", 1);
        var before = Categories.ClassifyCalls;
        var c = it.Category;
        for (var i = 0; i < 5; i++) Assert.Equal(c, it.Category);
        Assert.Equal(1, Categories.ClassifyCalls - before);
        var changed = it with { Title = "Hackers breach security of a bank with ransomware" };
        Assert.Equal(Categories.Classify(changed.Title + "  "), changed.Category);
    }

    // MARK: storySeen
    // DB 에서 지워진 스토리의 '본 보도 수' 기억은 정리한다(끝없이 쌓이지 않게)
    [Fact]
    public async Task StorySeenDropsStoriesGoneFromDatabase()
    {
        var db = Db();
        var mag = new Magazine(db);
        var model = new AppModel(new FakeUi(), mag, new AppState(), persist: false) { ShowAllSourcesForTests = true };
        SeedStories(mag, 1);
        var live = mag.Stories().Single().Id;
        model.MarkStorySeen(live, 2);
        model.MarkStorySeen("GONE-STORY", 3);
        await model.CheckAllAsync();
        Assert.Equal([live], model.State.StorySeen.Keys.ToList());
    }

    // MARK: 이어 하는 확인
    // 확인 도중 켠 출처를 곧바로 한 번 더 확인할 때도 화면 스레드(처음 확인을 부른 문맥)에서 돈다 — 스레드 풀에서 State·pendingFill·알림을 건드리지 않게
    [Fact]
    public void FollowUpCheckRunsOnUiContext()
    {
        var model = new AppModel(new FakeUi(), new Magazine(Db()), new AppState(), persist: false) { ShowAllSourcesForTests = true };
        model.State.Enabled["ghost"] = true;   // 켰지만 이번 확인에서 받지 못한 출처(목록에 없어 늘 다시 확인 대상)
        model.PendingFillForTests.Add("ghost");
        var ui = new QueueContext();
        var done = 0;   // 끝난 확인 수(Checking 이 꺼질 때만 false 로 Changed)
        var offUi = 0;
        model.Changed += () =>
        {
            if (SynchronizationContext.Current != ui) Interlocked.Increment(ref offUi);
            if (!model.Checking) Interlocked.Increment(ref done);
        };
        ui.Post(_ => _ = model.CheckAllAsync(), null);
        var until = DateTime.UtcNow.AddSeconds(10);
        while (Volatile.Read(ref done) < 2 && DateTime.UtcNow < until) { ui.Pump(); Thread.Sleep(5); }
        model.State.Enabled["ghost"] = false;   // 되풀이를 멈춘다
        for (var i = 0; i < 40; i++) { ui.Pump(); Thread.Sleep(5); }
        Assert.True(done >= 2, $"이어 하는 확인이 돌지 않음({done})");
        Assert.Equal(0, offUi);
    }

    // 화면 스레드 대신: 넣은 일을 시험 스레드가 Pump 할 때만 차례로 돌린다
    private sealed class QueueContext : SynchronizationContext
    {
        private readonly System.Collections.Concurrent.ConcurrentQueue<(SendOrPostCallback, object?)> q = new();
        public override void Post(SendOrPostCallback d, object? state) => q.Enqueue((d, state));
        public override void Send(SendOrPostCallback d, object? state) => throw new NotSupportedException();
        public void Pump()
        {
            var before = Current;
            SetSynchronizationContext(this);
            try { while (q.TryDequeue(out var w)) w.Item1(w.Item2); }
            finally { SetSynchronizationContext(before); }
        }
    }
}
