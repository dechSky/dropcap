using System.Collections.Concurrent;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Dropcap.Core;

// 한국어 번역. 윈도우에는 무료 기기 내 번역이 없으므로(T-05 ⊘) 구글 번역 공개 엔드포인트(gtx)를 쓴다.
// 실패하면 원문을 그대로 돌려준다.
public sealed class Translator
{
    public static readonly Translator Shared = new();
    public Translator() { }

    public const string EngineGoogle = "Google 번역";
    public const string EngineNone = "번역 안 함";

    // 번역 방식(맥과 같은 설정 키 translateEngine · 값 auto|apple|google|off).
    // 윈도우엔 기기 내 번역이 없어 auto = Google. apple(맥에서 '기기 내만'으로 고른 기록을 가져온 것)은 기기 밖으로 보내지 않는다는 뜻이라 여기선 번역 안 함.
    public static readonly string[] Modes = ["auto", "apple", "google", "off"];
    public static string NormalizeMode(string? v) => v is not null && Modes.Contains(v) ? v : "auto"; // 모르는 값은 자동(맥과 같음)
    public static bool Sends(string mode) => mode is "auto" or "google";

    // 지금 번역 방식(AppModel 이 설정을 넣어 줌 — 시험은 바꿔 끼움)
    public Func<string> ModeSource { get; set; } = () => "auto";
    private string? lastMode;
    // 방식이 바뀌면 캐시를 비운다(앞서 다른 방식으로 한 번역이 섞이지 않게 — 맥과 같음)
    private void FollowMode()
    {
        var m = NormalizeMode(ModeSource());
        if (lastMode is not null && lastMode != m) cache.Clear();
        lastMode = m;
    }
    private bool IsOff() { FollowMode(); return !Sends(lastMode!); }
    public bool Sending => !IsOff();   // 지금 방식이 번역을 보내는가(화면 안내용)

    private readonly ConcurrentDictionary<string, string> cache = new();
    public string LastEngine { get; private set; } = EngineNone;

    // 번역 요청 하나의 전체 시간 상한(시험에서만 줄인다). 넘으면 원문 그대로 — 확인이 제목 번역을 기다리다 멈추지 않게
    internal TimeSpan RequestDeadline { get; set; } = TimeSpan.FromSeconds(15);   // 예전 요청 상한(15초)과 같게
    // 시간 상한에 걸린 뒤 잠시는 구글을 부르지 않는다(묶음 실패 뒤 문단마다 다시 보내며 상한을 수십 번 기다리지 않게)
    public static readonly TimeSpan GoogleBackoff = TimeSpan.FromSeconds(60);
    private long quietUntil;   // Environment.TickCount64 기준(벽시계가 바뀌어도 그대로)
    private bool Resting => Environment.TickCount64 < Interlocked.Read(ref quietUntil);
    private void Rest() => Interlocked.Exchange(ref quietUntil, Environment.TickCount64 + (long)GoogleBackoff.TotalMilliseconds);

    // 시험에서 네트워크 없이 바꿔 끼우기 위한 자리(text, target) → 번역 또는 null
    internal Func<string, string, Task<string?>>? Backend { get; set; }

    // 오래 켜 둬도 무한히 커지지 않게 4000개를 넘으면 비운다(T-03 — 기사 본문 번역도 여기로 모이므로 이 한 곳에서 지킨다)
    public const int CacheLimit = 4000;
    public int CacheCount => cache.Count;
    public void Remember(string source, string translated)
    {
        if (cache.Count >= CacheLimit) cache.Clear();
        cache[source] = translated;
    }

    // T-01: 한글 비율 20% 미만이면 번역 대상. 글자가 하나도 없거나(숫자·기호뿐) 주소 하나뿐인 글은 번역할 것이 없다(맥과 같음)
    public static bool LooksForeign(string text)
    {
        var s = text.Where(c => !char.IsWhiteSpace(c)).ToArray();
        if (s.Length == 0 || !s.Any(char.IsLetter)) return false;
        if (s.Length == text.Trim().Length && UrlOnly.IsMatch(text.Trim())) return false;
        var hangul = s.Count(c => c >= '가' && c <= '힣');
        return (double)hangul / s.Length < 0.2;
    }

    private static readonly Regex UrlOnly = new(@"^(https?://|www\.)\S+$", RegexOptions.IgnoreCase);

    // MARK: 다듬기(번역 결과 후처리 — 맥 Translator.polish 와 같은 규칙)

    // 원문 끝에 마침표가 없으면(제목·소제목·목록) 번역 끝 마침표를 뗀다(케이스 3),
    // 원문에 영문으로 있는 이름을 엔진이 한글로 음역·직역했으면 영문으로 되돌린다(케이스 2)
    public static string Polish(string source, string translated)
    {
        var t = translated;
        var src = source.Trim();
        if (src.Length > 0 && !".。!?！？…:;\"”’)".Contains(src[^1]))
        {
            var tt = t.Trim();
            if (tt.EndsWith('.') && !tt.EndsWith("..")) t = tt[..^1];
        }
        return RestoreNames(source, t);
    }

    // 엔진이 잘 음역·직역하는 이름(AI 뉴스에 자주 나오는 것). 긴 꼴부터 바꾼다. 원문에 그 영문 이름이 낱말로 있을 때만.
    // PersonClash: 사람 이름 앞부분이 되기도 하는 이름 — 원문에서 그 이름 바로 뒤에 다른 대문자 낱말(제품 이름 아님)이 오면 건드리지 않는다
    public sealed record NameRule(string Latin, string[] Variants, bool PersonClash = false);
    public static readonly NameRule[] NameRules =
    [
        new("Claude Code", ["클로드 코드"]),
        new("Claude Corps", ["클로드 군단", "클로드 코어스", "클로드 코프스", "클로드 코퍼스"]),
        new("Claude", ["클로드", "클도"], PersonClash: true),
        new("Anthropic", ["앤트로픽", "앤스로픽", "안트로픽", "인류학적"]),
        new("OpenAI", ["오픈AI", "오픈에이아이", "오픈 AI"]),
        new("ChatGPT", ["챗GPT", "챗지피티"]),
        new("Gemini", ["제미니", "제미나이", "쌍둥이자리"]),
        new("DeepMind", ["딥마인드"]),
        new("Hugging Face", ["포옹하는 얼굴", "허깅 페이스", "허깅페이스"]),
        new("Copilot", ["부조종사", "코파일럿"]),
        new("Perplexity", ["당혹감", "퍼플렉시티"]),
    ];
    public static readonly HashSet<string> ProductWords = ["Code", "Corps", "Opus", "Sonnet", "Haiku", "Fable", "Mythos", "Design", "Science",
                                                           "Security", "Cowork", "Enterprise", "Pro", "Max", "Team", "Ultra", "Flash", "Nano"];

    public static string RestoreNames(string source, string translated)
    {
        var t = translated;
        foreach (var r in NameRules)
        {
            if (!r.Variants.Any(t.Contains)) continue;
            if (!Regex.IsMatch(source, "(?<![A-Za-z])" + Regex.Escape(r.Latin) + "(?![A-Za-z])")) continue;
            if (r.PersonClash && FollowedByOtherName(source, r.Latin)) continue;
            foreach (var v in r.Variants.OrderByDescending(v => v.Length)) t = t.Replace(v, r.Latin);
        }
        return t;
    }

    // 원문에서 name 바로 뒤에 제품 낱말이 아닌 대문자 낱말이 오는가(예: 사람 이름 'Claude Monet')
    public static bool FollowedByOtherName(string source, string name) =>
        Regex.Matches(source, "(?<![A-Za-z])" + Regex.Escape(name) + " ([A-Z][a-z]+)").Any(m => !ProductWords.Contains(m.Groups[1].Value));

    // 묶음 대조(케이스 10): 문단 수는 맞아도 결과가 밀렸는지. 원문 문단에만 있는(앞뒤 원문에는 없는) 영문 낱말·숫자 —
    // 번역에도 그대로 남는 것 — 가 제 짝 번역보다 이웃 짝 번역에 더 많이 보이는 문단이 하나라도 있으면 밀린 것으로 본다.
    // 틀리게 의심하면 그 묶음을 문단별로 다시 받을 뿐이다(맥 점검 표본 85묶음: 오탐 1, 한 칸 밀림 84/85).
    public static HashSet<string> Anchors(string s) =>
        Regex.Matches(s, "[A-Za-z][A-Za-z0-9]{2,}|[0-9]{2,}").Select(m => m.Value.ToLowerInvariant()).ToHashSet();

    public static bool LooksShifted(IReadOnlyList<string> sources, IReadOnlyList<string> outputs)
    {
        if (sources.Count != outputs.Count || sources.Count < 2) return false;
        var src = sources.Select(Anchors).ToList();
        var o = outputs.Select(Anchors).ToList();
        var n = sources.Count;
        for (var k = 0; k < n; k++)
        {
            var own = new HashSet<string>(src[k]);
            if (k > 0) own.ExceptWith(src[k - 1]);
            if (k + 1 < n) own.ExceptWith(src[k + 1]);
            if (own.Count == 0) continue;
            var mine = own.Count(o[k].Contains);
            var next = k + 1 < n ? own.Count(o[k + 1].Contains) : 0;
            var prev = k > 0 ? own.Count(o[k - 1].Contains) : 0;
            if (Math.Max(next, prev) > mine) return true;
        }
        return false;
    }

    // 한국어 제목을 영어로(같은 소식 비교용). 실패하면 null.
    public async Task<string?[]> ToEnglishAsync(IReadOnlyList<string> texts) =>
        IsOff() ? new string?[texts.Count] : await Task.WhenAll(texts.Select(t => Google(t, "en")));

    public async Task<string> TranslateAsync(string text)
    {
        var src = text.Trim();
        if (IsOff() || !LooksForeign(src)) return text;
        if (cache.TryGetValue(src, out var c)) return c;
        return (await TranslateManyAsync([src])).FirstOrDefault() ?? src;
    }

    public async Task<List<string>> TranslateManyAsync(IReadOnlyList<string> texts) => (await TranslateManyReportingAsync(texts)).Texts;

    // 번역과 함께 '이번 번역에 쓴 엔진'(T-08: 앱 전체에 하나인 LastEngine 은 다른 번역이 동시에 돌면 틀리게 보였다).
    // 윈도우는 엔진이 구글 하나라 새로 번역했거나 캐시(=구글 번역 결과)에서 꺼낸 것이 있으면 구글, 번역할 것이 없었으면 '번역 안 함'.
    public async Task<(List<string> Texts, string Engine)> TranslateManyReportingAsync(IReadOnlyList<string> texts)
    {
        if (IsOff()) return (texts.ToList(), EngineNone); // 번역 안 함: 아무것도 보내지 않고 원문 그대로
        var cached = texts.Any(t => cache.ContainsKey(t));
        var (o, fresh) = await TranslateManyRawAsync(texts);
        return (o, fresh || cached ? EngineGoogle : EngineNone);
    }

    // 여러 문단을 한 번에. 순서를 지킨다(T-02). 새로 번역했는지를 함께 돌려준다
    private async Task<(List<string> Texts, bool Fresh)> TranslateManyRawAsync(IReadOnlyList<string> texts)
    {
        var result = texts.ToList();
        var todo = new List<int>();
        for (var i = 0; i < texts.Count; i++)
        {
            if (cache.TryGetValue(texts[i], out var hit)) result[i] = hit;
            else if (LooksForeign(texts[i])) todo.Add(i);
        }
        if (todo.Count == 0) return (result, false);

        // 문단 여러 개를 빈 줄로 이어 한 번에 보내고(요청 수를 줄여 빠르게), 묶음들은 동시에 보낸다.
        // 돌아온 문단 수가 안 맞으면 그 묶음만 문단별로 다시 보낸다.
        var batches = new List<List<int>> { new() };
        var size = 0;
        foreach (var i in todo)
        {
            var n = texts[i].Length;
            if (size + n > 3800 && batches[^1].Count > 0) { batches.Add(new()); size = 0; }
            batches[^1].Add(i);
            size += n + 2;
        }
        // 묶음은 동시에 ParallelBatches 개까지, 문단별 다시 보내기는 번역 한 번에 RetryLimit 개까지(넘는 문단은 원문 그대로) —
        // 표가 큰 기사 하나가 요청을 한꺼번에 수백 건 보내지 않게
        using var gate = new SemaphoreSlim(ParallelBatches);
        var retries = RetryLimit;
        var outs = await Task.WhenAll(batches.Where(b => b.Count > 0).Select(async batch =>
        {
            await gate.WaitAsync();
            try
            {
                var sources = batch.Select(i => texts[i].Replace("\n", " ")).ToList();
                if (await Google(string.Join("\n\n", sources), "ko") is { } got)
                {
                    var parts = got.Split("\n\n").Select(p => p.Trim()).Where(p => p.Length > 0).ToList();
                    // 수는 맞아도 앞뒤 문단과 엇갈려 보이면(케이스 10) 문단별로 다시
                    if (parts.Count == batch.Count && !LooksShifted(sources, parts)) return batch.Zip(parts).ToList();
                }
                var one = new List<(int, string)>();
                foreach (var i in batch)
                {
                    if (Interlocked.Decrement(ref retries) < 0) break;
                    if (await Google(texts[i], "ko") is { } t) one.Add((i, t));
                }
                return one;
            }
            finally { gate.Release(); }
        }));
        foreach (var pairs in outs)
            foreach (var (i, raw) in pairs) { var t = Polish(texts[i], raw); result[i] = t; Remember(texts[i], t); }
        LastEngine = EngineGoogle;
        return (result, true);
    }

    // 구글 묶음 동시 개수 · 번역 한 번의 문단별 다시 보내기 상한
    public const int ParallelBatches = 4;
    public const int RetryLimit = 40;

    // 한 번에 보낼 수 있는 길이(구글 공개 엔드포인트). 이보다 긴 문단은 문장 단위로 나눠 보내고 이어 붙인다(T-08: 예전엔 뒤가 잘렸다)
    public const int RequestLimit = 4500;

    private async Task<string?> Google(string text, string target)
    {
        if (text.Length <= RequestLimit) return await GoogleOnce(text, target);
        var parts = new List<string>();
        foreach (var chunk in SentenceChunks(text, RequestLimit))
        {
            if (await GoogleOnce(chunk, target) is not { } t) return null;
            parts.Add(t);
        }
        return string.Join(" ", parts);
    }

    // 문장 경계에서 max 글자 이하로 묶는다. 한 문장이 max 보다 길면 그 문장만 max 씩 자른다. 이어 붙이면 원문 그대로(맥 sentenceChunks).
    // 맥은 기기 내 문장 나누기(NLTokenizer), 여기는 문장 끝 부호(. ! ? 。 ！ ？ …) 뒤 공백에서 나눈다(공백은 앞 문장에 붙임)
    public static List<string> SentenceChunks(string text, int max)
    {
        if (text.Length <= max) return [text];
        var sentences = System.Text.RegularExpressions.Regex.Split(text, @"(?<=[.!?。！？…][""'”’)\]]?\s)").Where(s => s.Length > 0).ToList();
        var o = new List<string>();
        var cur = new System.Text.StringBuilder();
        foreach (var s in sentences)
        {
            if (s.Length > max)
            {
                if (cur.Length > 0) { o.Add(cur.ToString()); cur.Clear(); }
                var rest = s;
                while (rest.Length > max) { o.Add(rest[..max]); rest = rest[max..]; }
                cur.Append(rest);
            }
            else if (cur.Length + s.Length > max) { o.Add(cur.ToString()); cur.Clear().Append(s); }
            else cur.Append(s);
        }
        if (cur.Length > 0) o.Add(cur.ToString());
        return o;
    }

    private async Task<string?> GoogleOnce(string text, string target)
    {
        if (Resting) return null;
        using var cts = new CancellationTokenSource();
        var work = Backend is { } b ? b(text, target) : GoogleRequest(text, target, cts.Token);
        var deadline = Task.Delay(RequestDeadline, cts.Token);
        if (await Task.WhenAny(work, deadline) != work)
        {
            cts.Cancel();   // 요청을 끊는다
            Rest();
            return null;
        }
        cts.Cancel();   // 기다리던 시계를 치운다
        try { return await work; }
        catch (OperationCanceledException) { Rest(); return null; }   // 요청 자체의 시간 상한(SafeHttp)에 걸림
        catch { return null; }
    }

    private async Task<string?> GoogleRequest(string text, string target, CancellationToken ct)
    {
        var q = FeedParser.Prefix(text, RequestLimit);
        var url = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=" + target + "&dt=t&q=" + Uri.EscapeDataString(q);
        try
        {
            var r = await SafeHttp.GetAsync(url, timeout: RequestDeadline, maxBody: 2L << 20, ct: ct);   // 번역 응답은 2MB 까지(보안 점검)
            if (r.Status != 200) return null;
            using var doc = JsonDocument.Parse(r.Body);
            if (doc.RootElement.ValueKind != JsonValueKind.Array || doc.RootElement.GetArrayLength() == 0) return null;
            var segs = doc.RootElement[0];
            if (segs.ValueKind != JsonValueKind.Array) return null;
            var sb = new System.Text.StringBuilder();
            foreach (var seg in segs.EnumerateArray())
                if (seg.ValueKind == JsonValueKind.Array && seg.GetArrayLength() > 0 && seg[0].ValueKind == JsonValueKind.String)
                    sb.Append(seg[0].GetString());
            return sb.Length == 0 ? null : sb.ToString();
        }
        catch (OperationCanceledException) { throw; }   // 시간 상한 — GoogleOnce 가 쉬기로
        catch
        {
            return null;
        }
    }
}
