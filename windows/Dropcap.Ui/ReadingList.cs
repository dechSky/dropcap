using Dropcap.Core;

namespace Dropcap.Ui;

// 읽기 창에서 J·K 로 넘길 목록(H-05): 기사를 연 곳(상단바 목록·매거진 지면)의 순서. 맥 ReaderController.step 과 같음.
// 열 때 Remember(연 기사, 그 목록), 읽기 창이 Step(지금 기사, ±1) — 영상·팟캐스트는 건너뛰고, 끝이면 null(경고음).
public static class ReadingList
{
    private static readonly object gate = new();
    private static readonly Dictionary<string, List<NewsItem>> byKey = new();

    public static void Remember(NewsItem opened, IEnumerable<NewsItem> sequence)
    {
        var list = sequence.ToList();
        if (list.All(i => i.Key != opened.Key)) list = [opened];
        lock (gate)
        {
            byKey[opened.Key] = list;
            if (byKey.Count > 50) byKey.Remove(byKey.Keys.First()); // 오래 켜 둬도 끝없이 커지지 않게
        }
    }

    public static IReadOnlyList<NewsItem> Of(string key) { lock (gate) return byKey.TryGetValue(key, out var l) ? l : []; }

    public static NewsItem? Step(string key, int dir)
    {
        List<NewsItem>? list;
        lock (gate) if (!byKey.TryGetValue(key, out list)) return null;
        var i = list.FindIndex(x => x.Key == key);
        if (i < 0) return null;
        for (var j = i + dir; j >= 0 && j < list.Count; j += dir)
        {
            if (list[j].ItemKind.OpensExternally()) continue;
            lock (gate) byKey[list[j].Key] = list;
            return list[j];
        }
        return null;
    }
}
