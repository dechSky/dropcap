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
                var want = Environment.GetEnvironmentVariable("DROPCAP_OLLAMA_MODEL");
                model = names.FirstOrDefault(n => want is not null && n.StartsWith(want, StringComparison.OrdinalIgnoreCase))
                    ?? names.FirstOrDefault(n => !n.Contains("embed", StringComparison.OrdinalIgnoreCase));
            }
            catch { model = null; }
            probe = (model, DateTime.UtcNow);
            return model is not null;
        }
        finally { gate.Release(); }
    }

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
