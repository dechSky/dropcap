using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Dropcap.Core;

// 기사 3줄 요약(T-06). 맥은 Apple Intelligence, 윈도우는 이 PC 에 Ollama 가 켜져 있으면 그걸로 만든다(무료·비공개).
// 없으면 null 을 돌려주고, 읽기 창은 요약 칸을 숨긴다.
//
// 안전(S 절) 예외: 사용자가 직접 켠 로컬 서비스라 http://127.0.0.1:11434 한 곳만 허용한다.
// 이 주소는 고정이고(피드·설정에서 바꿀 수 없음), 이 클라이언트는 다른 곳에 요청하지 않는다.
public static class Summarizer
{
    public const string OllamaBase = "http://127.0.0.1:11434";
    private static readonly HttpClient local = new(new SocketsHttpHandler { UseProxy = false, AllowAutoRedirect = false })
    {
        BaseAddress = new Uri(OllamaBase),
    };

    private static (string? Model, DateTime At) probe;
    private static readonly SemaphoreSlim gate = new(1, 1);

    public static string? Model => probe.Model;

    // 설정 화면 표시용(P-04)
    public static string Status => probe.Model is { } m ? $"Ollama({m})로 이 PC 안에서 요약합니다" : "Ollama 가 없어 요약 칸을 숨깁니다";

    // 켜져 있는지와 쓸 모델(1분 기억)
    public static async Task<bool> AvailableAsync()
    {
        await gate.WaitAsync();
        try
        {
            if (DateTime.UtcNow - probe.At < TimeSpan.FromMinutes(1)) return probe.Model is not null;
            string? model = null;
            try
            {
                using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(1.5));
                var tags = await local.GetFromJsonAsync<JsonObject>("/api/tags", cts.Token);
                var names = (tags?["models"] as JsonArray)?.Select(m => m?["name"]?.GetValue<string>()).OfType<string>().ToList() ?? new();
                model = PickModel(names, Environment.GetEnvironmentVariable("DROPCAP_OLLAMA_MODEL"));
            }
            catch { model = null; }
            probe = (model, DateTime.UtcNow);
            return model is not null;
        }
        finally { gate.Release(); }
    }

    // 쓸 모델: 정한 이름(DROPCAP_OLLAMA_MODEL — 그 이름이거나 "이름:태그")이 있으면 그것만, 없으면 첫 글 모델.
    // 임베딩 전용과 Ollama 클라우드 모델(이름에 cloud, 예 gpt-oss:120b-cloud — 글을 바깥 서버로 보냄)은 '이 PC 안' 요약이 아니라 뺀다(리눅스와 같음)
    public static string? PickModel(IReadOnlyList<string> names, string? want)
    {
        if (!string.IsNullOrWhiteSpace(want))
            return names.FirstOrDefault(n => (string.Equals(n, want, StringComparison.OrdinalIgnoreCase) || n.StartsWith(want + ":", StringComparison.OrdinalIgnoreCase)) && LocalTextModel(n));
        return names.FirstOrDefault(LocalTextModel);
    }

    public static bool LocalTextModel(string name) =>
        !name.Contains("embed", StringComparison.OrdinalIgnoreCase) && !name.Contains("cloud", StringComparison.OrdinalIgnoreCase);

    public const string Instructions = """
        당신은 뉴스 편집자입니다. 기사를 읽고 핵심만 한국어로 세 줄 요약합니다.
        각 줄은 "- " 로 시작하고 60자 안팎의 한 문장입니다. 기사에 없는 내용은 쓰지 않습니다.
        """;

    public static async Task<List<string>?> SummarizeAsync(string title, IReadOnlyList<string> paragraphs)
    {
        if (!await AvailableAsync() || probe.Model is not { } model) return null;
        // 모델이 한 번에 읽을 수 있는 양에 맞춰 앞부분만
        var body = new System.Text.StringBuilder();
        foreach (var p in paragraphs) { if (body.Length >= 6000) break; body.Append(p).Append('\n'); }
        if (body.Length <= 200) return null;
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(120));
            var resp = await local.PostAsJsonAsync("/api/generate", new
            {
                model,
                system = Instructions,
                prompt = $"제목: {title}\n\n본문:\n{body}",
                stream = false,
                options = new { temperature = 0.2 },
            }, cts.Token);
            if (!resp.IsSuccessStatusCode) return null;
            var json = await resp.Content.ReadFromJsonAsync<JsonObject>(cts.Token);
            return ParseLines(json?["response"]?.GetValue<string>() ?? "");
        }
        catch { return null; }
    }

    // 분야별 저녁 정리(N-26 · D-13): 묶음으로 모인 기사들로 "오늘 이 분야에서 무슨 일이 · 왜" 세 줄. 줄마다 근거 기사 번호를 단다.
    // 맥은 Apple Intelligence, 윈도우는 이 PC 의 Ollama(T-06 과 같은 곳). 없으면 null — 매거진에 상자를 싣지 않는다.
    public const string BriefingInstructions = """
        당신은 뉴스 편집자입니다. 번호가 붙은 기사 제목과 요약만 읽고, 오늘 이 분야에서 무슨 일이 있었고 왜 중요한지 한국어 세 줄로 정리합니다.
        각 줄은 "- " 로 시작하는 60자 안팎의 한 문장이고, 줄 끝에 근거가 된 기사 번호를 [1] 이나 [1][3] 처럼 붙입니다.
        기사에 없는 내용·추측·평가는 쓰지 않습니다.
        """;

    public static async Task<List<SectionBrief.Line>?> BriefingAsync(string section, IReadOnlyList<NewsItem> items)
    {
        if (items.Count < 2 || !await AvailableAsync() || probe.Model is not { } model) return null;
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(120));
            var resp = await local.PostAsJsonAsync("/api/generate", new
            {
                model,
                system = BriefingInstructions,
                prompt = BriefingPrompt(section, items),
                stream = false,
                options = new { temperature = 0.2 },
            }, cts.Token);
            if (!resp.IsSuccessStatusCode) return null;
            var json = await resp.Content.ReadFromJsonAsync<JsonObject>(cts.Token);
            return ParseBriefing(json?["response"]?.GetValue<string>() ?? "", items.Count);
        }
        catch { return null; }
    }

    public static string BriefingPrompt(string section, IReadOnlyList<NewsItem> items)
    {
        var o = new System.Text.StringBuilder($"분야: {section}\n");
        for (var i = 0; i < items.Count; i++)
        {
            var it = items[i];
            o.Append($"\n[{i + 1}] {it.Title}");
            if (it.TitleKo is { } ko && ko != it.Title) o.Append($" ({ko})");
            o.Append($" — {it.SourceName}\n");
            var sum = System.Text.RegularExpressions.Regex.Replace(it.Summary, @"\s+", " ");
            if (sum.Length > 300) sum = sum[..300];
            if (sum.Length > 0) o.Append(sum).Append('\n');
        }
        return o.ToString();
    }

    // 모델 답을 줄로: "- 문장 [1][3]" → (문장, [0, 2]). 근거 번호가 없거나 범위를 벗어난 줄은 버린다(근거 없는 요약은 싣지 않음)
    public static List<SectionBrief.Line>? ParseBriefing(string text, int count)
    {
        var re = new System.Text.RegularExpressions.Regex(@"\[(\d+)\]");
        var o = new List<SectionBrief.Line>();
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Trim();
            if (!(line.StartsWith('-') || line.StartsWith('•'))) continue;
            var body = line.TrimStart('-', '•', ' ');
            var refs = new List<int>();
            foreach (System.Text.RegularExpressions.Match m in re.Matches(body))
                if (int.TryParse(m.Groups[1].Value, out var n) && n >= 1 && n <= count && !refs.Contains(n - 1)) refs.Add(n - 1);
            var clean = re.Replace(body, "").Trim();
            if (refs.Count == 0 || clean.Length == 0) continue;
            o.Add(new SectionBrief.Line(clean, refs));
        }
        return o.Count == 0 ? null : o.Take(3).ToList();
    }

    // "- " 또는 "•" 로 시작하는 줄만, 최대 3줄
    public static List<string>? ParseLines(string text)
    {
        var lines = text.Split('\n').Select(l => l.Trim())
            .Where(l => l.StartsWith('-') || l.StartsWith('•'))
            .Select(l => l.TrimStart('-', '•', ' '))
            .Where(l => l.Length > 0).Take(3).ToList();
        return lines.Count == 0 ? null : lines;
    }
}

// 분야별 저녁 정리: 묶음을 보낸 때의 기사(근거)와 기기 안 요약(없을 수 있음)
public sealed record SectionBrief
{
    public sealed record Line(string Text, List<int> Refs); // Refs: Items 의 번호(0부터)
    public string Section { get; init; } = "";
    public DateTimeOffset At { get; init; }
    public List<NewsItem> Items { get; init; } = new();      // 근거 기사(원제목·링크)
    public List<Line>? Lines { get; init; }                  // 요약 모델이 없으면 null — 매거진에는 싣지 않고 알림은 지금처럼 제목 2줄

    public const int MaxItems = 8;
}
