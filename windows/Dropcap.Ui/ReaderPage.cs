using System.Globalization;
using System.Text.RegularExpressions;
using System.Text.Json.Nodes;
using Dropcap.Core;

namespace Dropcap.Ui;

// 읽기 창(R 절). 창은 기사마다 하나씩 여러 개 — 주소는 reader.html?key=<기사 키>.
// 맥 ReaderView 와 같은 내용·문구. 본문 추리기·번역·요약은 ArticleService 가 하고, 여기서는 보기 데이터를 만들어 보낸다.
public sealed class ReaderPage : IPage
{
    public string Name => "reader";

    public const int MinFont = 13, MaxFont = 26, DefaultFont = 17; // R-06

    private readonly AppModel model;
    private readonly ArticleService articles;
    private readonly Scrapbook book;
    private readonly IPlatform platform;
    private readonly Bridge bridge;
    private readonly PaywallBook? paywall;                      // 시험에서 넣는 것. 없으면 PaywallBook.Shared
    private readonly object gate = new();
    private readonly Dictionary<string, Entry> open = new();   // 기사 키 → 열린 창의 기사·진행 상황
    private string? speakingKey;                                // 지금 소리 내어 읽는 창

    private sealed class Entry(NewsItem item)
    {
        public NewsItem Item { get; } = item;
        public PreparedArticle? Article { get; set; }
        public Guid? Token { get; set; }
        public (bool Done, string? Url)? Cover { get; set; }   // 고른 표지(R-22). 고르기 전에는 null — 피드 사진·매거진 기록을 먼저 보임
    }

    // 표지 고르기(R-22)에 쓰는 받기: 사진의 가로 크기 · 기사 머리 대표 사진 주소. 시험에서 바꿔 끼운다
    public Func<string, Task<int?>> ImageWidth { get; set; } = u => ImageLoader.Shared.WidthAsync(u);
    public Func<string, Task<string?>> OgImage { get; set; } = CoverPick.OgImageAsync;
    // 사진 바이트(R-20): 안전 로더(공개 주소만·8MB·1400px)
    public Func<string, Task<byte[]?>> ImageBytes { get; set; } = u => ImageLoader.Shared.JpegAsync(u);

    public ReaderPage(AppModel model, ArticleService articles, Scrapbook book, IPlatform platform, Bridge bridge, PaywallBook? paywall = null)
    {
        this.paywall = paywall;
        this.model = model;
        this.articles = articles;
        this.book = book;
        this.platform = platform;
        this.bridge = bridge;
        // 저장·스크랩 표시가 바뀌면 열린 창에 알림(창은 marks 로 다시 물음)
        book.Changed += () => bridge.Emit(Name, "changed");
    }

    private PaywallBook Paywalls => paywall ?? PaywallBook.Shared;

    public static int FontSize => Math.Clamp((int)Math.Round(Prefs.Get("readerFontSize", (double)DefaultFont)), MinFont, MaxFont);

    // MARK: 창 열기·닫기(앱이 부름)

    // 창을 열기 전에: 기사를 기억하고 진행 상황을 받아 창에 보낸다. 이미 준비된 기사는 바로 뜬다(R-15).
    public void Opening(NewsItem item)
    {
        Entry e;
        lock (gate)
        {
            if (open.ContainsKey(item.Key)) return; // 같은 기사 창을 다시 열면 그대로
            open[item.Key] = e = new Entry(item) { Article = articles.Cached(item.Link) };
            e.Token = articles.Observe(item.Link, a => { lock (gate) e.Article = a; Send(e); });
        }
        _ = Run(e);
        _ = PickCover(e);
    }

    // 피드 사진이 작은 미리보기거나 받지 못하면 기사 머리 대표 사진으로 바꾸고, 대신할 것도 없으면 깨진 자리를 지운다(R-22)
    private async Task PickCover(Entry e)
    {
        var known = CoverPick.Known(e.Item.Image, model.Magazine.StoredImage(e.Item.Key));
        string? url;
        try { url = await CoverPick.FindAsync(known, e.Item.Link, ImageWidth, OgImage); }
        catch { return; }
        lock (gate) { if (!open.ContainsKey(e.Item.Key)) return; e.Cover = (true, url); }
        if (url != known) Send(e);
    }

    private async Task Run(Entry e)
    {
        PreparedArticle a;
        try { a = await articles.PrepareAsync(e.Item); }
        catch (Exception)
        {
            // 예외로 끝나도 실패 화면은 보여 준다(요약 번역 없이 원문 열기만)
            a = new PreparedArticle { Stage = Stage.Failed, Title = e.Item.DisplayTitle, OriginalTitle = e.Item.Title };
        }
        lock (gate) { if (!open.ContainsKey(e.Item.Key)) return; e.Article = a; }
        Send(e);
    }

    // 창을 닫으면: 관찰을 끊고, 이 창이 읽던 소리는 멈춘다(R-09)
    public void Closed(string key)
    {
        Entry? e;
        lock (gate)
        {
            if (!open.Remove(key, out e)) return;
            if (e.Token is { } t) articles.StopObserving(e.Item.Link, t);
        }
        if (speakingKey == key) { platform.StopSpeaking(); speakingKey = null; }
    }

    private void Send(Entry e)
    {
        PreparedArticle? a;
        (bool, string?)? cover;
        lock (gate) { a = e.Article; cover = e.Cover; }
        bridge.Emit(Name, "article", View(e.Item, a, model, book, Paywalls, cover));
    }

    // MARK: 보기 데이터

    // 맥 ReaderModel.Phase: 불러오는 중 → 번역 중(원문이 먼저 보임) → 끝 / 실패
    public static string Phase(PreparedArticle? a) => a?.Stage switch
    {
        null or Stage.Extracting => "loading",
        Stage.Original or Stage.Translating => "translating",
        Stage.Done => "done",
        _ => "failed",
    };

    // R-07: 읽는 시간. 한국어 분당 약 500자(빈칸 빼고), 외국어 분당 약 230낱말. 최소 1분, 글이 없으면 null.
    public static int? ReadingMinutes(IReadOnlyList<string> texts)
    {
        if (texts.Count == 0) return null;
        var joined = string.Join(" ", texts);
        var minutes = Translator.LooksForeign(joined)
            ? joined.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length / 230.0
            : joined.Count(c => !char.IsWhiteSpace(c)) / 500.0;
        return Math.Max(1, (int)Math.Round(minutes, MidpointRounding.AwayFromZero));
    }

    // R-12: 구글 번역 프록시 주소(맥 translatedPageURL 과 같은 모양). 호스트의 - 는 --, . 는 - 로.
    public static string? TranslatedPageUrl(string link)
    {
        if (!Uri.TryCreate(link, UriKind.Absolute, out var u) || (u.Scheme != "http" && u.Scheme != "https") || u.Host.Length == 0) return null;
        var h = u.Host.Replace("-", "--").Replace(".", "-");
        var q = (u.Query.Length > 1 ? u.Query[1..] + "&" : "") + "_x_tr_sl=auto&_x_tr_tl=ko&_x_tr_hl=ko";
        return $"https://{h}.translate.goog{u.AbsolutePath}?{q}";
    }

    // 피드 요약(HTML 꼬리표·여분 공백 제거, 제목과 같거나 너무 짧으면 없음) — 맥 ReaderView.feedSummary
    public static string? FeedSummary(NewsItem it)
    {
        var t = Regex.Replace(Plain.StripTags(it.Summary), @"\s+", " ").Trim();
        if (t.Length <= 30 || it.Title.StartsWith(t[..Math.Min(25, t.Length)], StringComparison.Ordinal)) return null;
        return t;
    }

    // 무료 보도를 먼저 권할 때와 그 이유(G-15, 맥 ReaderModel.freeReason): 유료로 알려진 곳이거나, 열어 보니 막혔을 때
    public static string? FreeReason(int alternatives, string phase, bool paywalled, PaywallKind? kind)
    {
        if (alternatives == 0) return null;
        if (phase == "failed") return "본문을 열지 못했습니다";
        if (paywalled) return "다른 곳 보도로 전체를 읽을 수 있어요"; // 맛보기 안내는 본문 위 띠(teaser)가 따로 맡는다(맥 TeaserBanner)
        if (kind is { } k && k.Blocks()) return k == PaywallKind.Hard ? "유료 기사입니다" : "이곳 기사는 자주 막힙니다";
        return null;
    }

    // 본문 끝 한 줄(맥 CutEndNote 문구 그대로). 맛보기도 일부만도 아니면 없음
    public static object? CutNote(bool teaser, bool partial) =>
        teaser ? new { text = "— 여기까지가 공개된 부분입니다", open = "원문에서 이어 읽기" }
        : partial ? new { text = "본문 일부만 가져왔을 수 있어요", open = "원문 열기" }
        : null;

    // 같은 스토리에서 무료로 읽을 수 있는 보도(숨긴 출처 빼고)
    public static List<NewsItem> Alternatives(NewsItem item, AppModel? m, PaywallBook? pw)
    {
        if (m is null || pw is null) return new();
        try { return pw.Alternatives(item, m.Magazine, m.State.HiddenSources.ToHashSet()); }
        catch { return new(); }
    }

    // 머리의 날짜: 맥 "10월 13일 오후 3:05" 모양
    public static string DateLabel(DateTimeOffset? d) =>
        d is { } v ? v.ToLocalTime().ToString("M월 d일 tt h:mm", CultureInfo.GetCultureInfo("ko-KR")) : "";

    // 창 하나에 보낼 전부. 번역/원문 전환은 창이 들고 있고, 두 쪽에 필요한 것(제목·원문·읽는 시간)을 함께 보낸다.
    // pickedCover: 표지 고르기(R-22)를 마쳤으면 (true, 고른 주소 — 없으면 null)
    public static object View(NewsItem item, PreparedArticle? a, AppModel? m, Scrapbook book, PaywallBook? pw = null, (bool Done, string? Url)? pickedCover = null)
    {
        var blocks = a?.Blocks ?? new();
        var byline = BodyCleanup.Analyze(blocks).Byline;   // 기자 줄 → 바이라인
        // 표지: 피드 사진 → 매거진이 받아 둔 대표 사진 → (작거나 못 받으면) 기사 머리 대표 사진 → 본문의 첫 사진(맥과 같은 순서).
        // 기자 프로필·로고 같은 잡그림은 빼고, 본문에서는 표지와 같은 사진(크기만 다른 것 포함)과 그 설명을 다시 싣지 않는다.
        var head = pickedCover is { Done: true } p ? p.Url : CoverPick.Known(item.Image, m?.Magazine.StoredImage(item.Key));
        var cover = head ?? blocks.FirstOrDefault(b => b.Type == BlockKind.Img && !ImageKey.IsJunk(b.Src))?.Src;
        var skip = BodyCleanup.Hidden(blocks, cover);   // 짝 잃은 설명 문구·기자 줄·표지와 같은 사진·잡그림·뺀 사진의 설명
        var shown = blocks.Select(b => b.Text).OfType<string>().ToList();
        var original = blocks.Select(b => b.Original ?? b.Text).OfType<string>().ToList();
        var phase = Phase(a);
        var title = a?.Title ?? item.DisplayTitle;
        var kind = pw?.SourceKind(item); // 맛보기 여부는 받은 본문의 Paywalled 가 맡는다(맥 ReaderView)
        var alts = Alternatives(item, m, pw);
        var paywalled = a?.Paywalled == true;
        var originalTitle = a?.OriginalTitle is { Length: > 0 } ot ? ot : item.Title;
        return new
        {
            key = item.Key,
            item = ItemView.From(item, m),
            phase,
            title,
            byline,
            originalTitle = a?.OriginalTitle ?? item.Title,
            translated = a?.Translated ?? false,
            engine = a?.Engine ?? "",
            // T-06: 요약이 있거나 요약 중일 때만 상자
            summary = a?.Summary,
            summarizing = a?.Summarizing ?? false,
            fallback = a?.Fallback ?? "",
            // 불러오는 동안·실패 화면에 보일 피드 요약, 앱에 본문을 내주지 않는 사이트인가
            feedSummary = FeedSummary(item),
            blockedHost = ArticleExtraction.IsBlockedLink(item.Link),
            // 번역된 웹페이지는 외국어 기사일 때만(한국어 기사엔 숨김)
            translatedPage = TranslatedPageUrl(item.Link) is not null && Translator.LooksForeign(originalTitle),
            // G-14·G-15: 유료 종류·맛보기만 나옴·같은 소식의 무료 보도와 권하는 이유
            paywall = kind?.Raw(),
            paywalled,
            alternatives = alts.Select(x => new { key = x.Key, source = x.SourceName, title = x.DisplayTitle, color = ItemView.From(x, m).Color }).ToList(),
            freeReason = FreeReason(alts.Count, phase, paywalled, kind),
            // 맛보기 띠(본문 위, 무료 보도가 없어도 늘 — 맥 TeaserBanner)와 본문 끝 한 줄(맛보기가 끝난 자리·일부만 — 맥 CutEndNote)
            teaser = paywalled && phase is ("translating" or "done"),
            cutNote = CutNote(paywalled, a?.Partial == true),
            cover,
            date = DateLabel(item.Date),
            minutes = new { shown = ReadingMinutes(shown), original = ReadingMinutes(original) },
            // 소리 내어 읽기(R-09): 번역이 없으면 제목 언어로 판단
            koreanTitle = !Translator.LooksForeign(title),
            blocks = blocks.Select((b, i) => (b, i))
                .Where(x => !skip.Contains(x.i))
                .Select(x => new
                {
                    i = x.i,
                    type = x.b.Type.ToString().ToLowerInvariant(),
                    text = x.b.Text ?? "",
                    original = x.b.Original is { } o && o != x.b.Text ? o : null,
                    src = x.b.Type == BlockKind.Img ? x.b.Src : null,
                    scrap = x.b.Type is BlockKind.P or BlockKind.Li or BlockKind.Quote or BlockKind.H,
                }).ToList(),
            marks = Marks(item, m, book),
            fontSize = FontSize,
        };
    }

    // 저장·스크랩 표시(자주 바뀌므로 따로 물을 수 있게)
    public static object Marks(NewsItem item, AppModel? m, Scrapbook book) => new
    {
        saved = m?.IsSaved(item) ?? false,
        scrapped = book.IsScrapped(item),
        scraps = book.Scraps.Where(s => s.Item.Key == item.Key && s.Quote is not null)
            .Select(s => new { quote = s.Quote, collection = s.Collection, memo = s.Memo }).ToList(),
        collections = book.Collections,
        lastCollection = book.LastCollection,
    };

    // MARK: 명령

    private Entry Find(string key)
    {
        lock (gate) if (open.TryGetValue(key, out var e)) return e;
        var it = Lookup.Find(model, key, model.Magazine) ?? throw new KeyNotFoundException("기사를 찾지 못함");
        Opening(it); // 앱이 Opening 을 부르지 않았거나 창을 새로 고친 경우
        lock (gate) return open[key];
    }

    private PreparedArticle? ArticleOf(Entry e) { lock (gate) return e.Article; }

    // 소리 내어 읽기: 보이는 언어의 제목과 본문(코드·사진 빼고)
    public static (string Text, string Language) SpeechFor(NewsItem item, PreparedArticle? a, bool showOriginal)
    {
        var title = a?.Title ?? item.DisplayTitle;
        var korean = a?.Translated == true ? !showOriginal : !Translator.LooksForeign(title);
        var paras = (a?.Blocks ?? new()).Where(b => b.Type is not (BlockKind.Pre or BlockKind.Img))
            .Select(b => (showOriginal ? b.Original : null) ?? b.Text).OfType<string>();
        var head = showOriginal ? a?.OriginalTitle ?? item.Title : title;
        var text = string.Join("\n\n", new[] { head }.Concat(paras).Where(t => t.Length > 0));
        return (text, korean ? "ko-KR" : "en-US");
    }

    // 문단 하나의 보이는 글과(번역문이면) 원문
    public static (string Quote, string? Original)? Paragraph(PreparedArticle? a, int index, bool showOriginal)
    {
        if (a is null || index < 0 || index >= a.Blocks.Count) return null;
        var b = a.Blocks[index];
        var text = (showOriginal ? b.Original : null) ?? b.Text;
        if (string.IsNullOrEmpty(text)) return null;
        return (text, showOriginal ? null : b.Original);
    }

    public async Task<object?> Handle(string cmd, JsonObject a) => cmd switch
    {
        "reload" => await Reload(a.Str("key")),
        "imageText" => await ImageTextOf(a.Str("key"), a.Str("src")),
        "imageTranslate" => await TranslateLines(a),
        "imageCopy" => await CopyImage(a.Str("key"), a.Str("src")),
        "imageSave" => await SaveImage(a.Str("key"), a.Str("src")),
        _ => Do(cmd, a),
    };

    // '다시 받기'(맥 ReaderModel.reload): 저장한 본문을 지우고 원문에서 처음부터. 진행 상황은 관찰로 창에 감
    private async Task<object?> Reload(string key)
    {
        var e = Find(key);
        lock (gate) e.Article = null;
        Send(e);   // 불러오는 중 화면으로
        PreparedArticle a;
        try { a = await articles.ReloadAsync(e.Item); }
        catch (Exception) { a = new PreparedArticle { Stage = Stage.Failed, Title = e.Item.DisplayTitle, OriginalTitle = e.Item.Title }; }
        lock (gate) { if (!open.ContainsKey(key)) return null; e.Article = a; }
        Send(e);
        return null;
    }

    // MARK: 기사 속 사진 도구(R-20)

    // 이 창의 기사에 실린 사진만(표지·본문) — 화면이 아무 주소나 받게 하지 않는다
    private bool ShowsImage(string key, string src)
    {
        if (src.Length == 0) return false;
        var e = Find(key);
        PreparedArticle? a;
        (bool, string?)? cover;
        lock (gate) { a = e.Article; cover = e.Cover; }
        return src == e.Item.Image || src == model.Magazine.StoredImage(e.Item.Key) || (cover is (true, { } c) && c == src)
            || (a?.Blocks.Any(b => b.Type == BlockKind.Img && b.Src == src) ?? false);
    }

    private async Task<byte[]?> BytesOf(string key, string src) => ShowsImage(key, src) ? await ImageBytes(src) : null;

    // 사진 속 글자 읽기: 줄마다 글·상자(0~1)·바탕색
    private async Task<object?> ImageTextOf(string key, string src)
    {
        if (await BytesOf(key, src) is not { } data) return new { lines = Array.Empty<object>() };
        IReadOnlyList<ImageText.Line> lines;
        try { lines = ImageText.Recognize is { } r ? await r(data) : []; }
        catch { lines = []; }
        return new { lines = ImageText.Describe(data, lines) };
    }

    // 외국어 줄만 번역. 번역하지 않은 줄은 null, 외국어 줄이 없으면 korean
    private static async Task<object?> TranslateLines(JsonObject a)
    {
        var texts = (a["texts"] as JsonArray ?? new JsonArray()).Select(n => n is JsonValue v && v.TryGetValue<string>(out var t) ? t : "").Take(500).ToList();
        if (!Translator.Shared.Sending) return new { @out = texts.Select(_ => (string?)null).ToList(), korean = false, off = true }; // 번역 안 함(W4)
        var (o, korean) = await ImageText.TranslateAsync(texts);
        return new { @out = o, korean, off = false };
    }

    private async Task<object?> CopyImage(string key, string src)
    {
        if (await BytesOf(key, src) is not { } data || ImageText.Copy is not { } copy) return new { ok = false };
        copy(data);
        return new { ok = true };
    }

    private async Task<object?> SaveImage(string key, string src)
    {
        if (await BytesOf(key, src) is not { } data || ImageText.Save is not { } save) return new { ok = false };
        return new { ok = await save(ImageText.SuggestedName(src), ext => ImageText.Encode(data, ext)) };
    }

    private object? Do(string cmd, JsonObject a)
    {
        var key = a.Str("key");
        Entry E() => Find(key);
        Scrap? ScrapOf(string quote) => book.Scraps.FirstOrDefault(s => s.Item.Key == key && s.Quote == quote);
        switch (cmd)
        {
            case "ready":
            case "view":
            {
                var e = E();
                (bool, string?)? cover;
                lock (gate) cover = e.Cover;
                return View(e.Item, ArticleOf(e), model, book, Paywalls, cover);
            }
            case "marks": return Marks(E().Item, model, book);
            case "fontSize":
            {
                var size = Math.Clamp(a.Int("size", DefaultFont), MinFont, MaxFont);
                Prefs.Set("readerFontSize", (double)size);
                bridge.Emit(Name, "fontSize", new { size }); // 열린 읽기 창 모두 같은 크기(맥 AppStorage 처럼)
                return new { size };
            }
            case "speak":
            {
                // 누를 때마다 읽기 ↔ 멈춤
                if (platform.Speaking) { platform.StopSpeaking(); speakingKey = null; return new { speaking = false }; }
                var e = E();
                var (text, lang) = SpeechFor(e.Item, ArticleOf(e), a.Bool("original"));
                platform.Speak(text, lang);
                speakingKey = key;
                return new { speaking = true };
            }
            case "speaking": return new { speaking = platform.Speaking && speakingKey == key };
            case "stopSpeak": platform.StopSpeaking(); speakingKey = null; return null;
            case "save": model.ToggleSaved(E().Item); return Marks(E().Item, model, book);
            case "browser": ExternalLink.Open(E().Item.Link); return null;
            case "openOriginal": ExternalLink.Open(E().Item.Link); return null;
            case "translatedPage": ExternalLink.Open(TranslatedPageUrl(E().Item.Link)); return null;
            case "share": platform.Share(E().Item); return null;
            case "copy": platform.CopyText(a.Str("text")); return null;
            case "scrapArticle":
            {
                book.Add(E().Item, collection: a.StrOrNull("collection"));
                return new { collection = book.LastCollection };
            }
            case "newCollection":
            {
                // 새 폴더를 만들고 기사를 그 폴더에 스크랩
                var name = a.Str("name").Trim();
                if (name.Length == 0) return null;
                book.CreateCollection(name);
                book.Add(E().Item, collection: name);
                return new { collection = name };
            }
            case "scrapParagraph":
            {
                var e = E();
                var p = Paragraph(ArticleOf(e), a.Int("index", -1), a.Bool("original")) ?? throw new InvalidOperationException("문단을 찾지 못함");
                book.Add(e.Item, quote: p.Quote, original: p.Original, collection: a.StrOrNull("collection"));
                return new { quote = p.Quote, collection = ScrapOf(p.Quote)?.Collection ?? book.LastCollection };
            }
            case "scrapSelection":
            {
                // 끌어서 고른 글만. 고른 글이 들어 있는 문단의 원문도 함께(번역문을 골랐을 때)
                var e = E();
                var text = a.Str("quote").Trim();
                if (text.Length == 0) return null;
                var orig = ArticleOf(e)?.Blocks.FirstOrDefault(b => (b.Text ?? "").Contains(text, StringComparison.Ordinal))?.Original;
                book.Add(e.Item, quote: text, original: orig);
                return new { quote = text, collection = book.LastCollection };
            }
            case "updateScrap":
            {
                if (ScrapOf(a.Str("quote")) is not { } s) return null;
                book.Update(s with { Collection = a.StrOrNull("collection") is { Length: > 0 } c ? c : s.Collection, Memo = a.StrOrNull("memo") ?? s.Memo });
                return null;
            }
            case "removeScrap":
                if (ScrapOf(a.Str("quote")) is { } r) book.Remove(r);
                return null;
            case "openAlternative":
            {
                // 같은 소식의 무료 보도: 읽음 표시하고 그 기사 읽기 창(지금 창은 그대로 — 원문 링크도 남음)
                var e = E();
                var alt = Alternatives(e.Item, model, Paywalls).FirstOrDefault(x => x.Key == a.Str("alt"));
                if (alt is null) return null;
                model.MarkOpened(alt);
                platform.OpenReader(alt);
                return null;
            }
            case "step":
            {
                // J·K(H-05): 연 목록의 다음·이전 기사를 같은 창에서. 끝이면 경고음
                var next = ReadingList.Step(key, a.Int("dir", 1) < 0 ? -1 : 1);
                if (next is null) { platform.Beep(); return new { moved = false }; }
                model.MarkOpened(next);
                platform.ReplaceReader(key, next);
                return new { moved = true };
            }
            case "close": platform.CloseWindow($"{Name}:{key}"); return null;
            default: throw new InvalidOperationException("모르는 명령 " + cmd);
        }
    }
}
