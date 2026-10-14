using Dropcap.Core;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;

namespace Dropcap.App;

// 시스템 알림(알림 센터) 방식을 고른 사람을 위해(N-18): 최대 3건 + "N건 더", 누르면 읽기 창
internal sealed class SystemNotifier
{
    private bool registered;
    public event Action<string>? Invoked;   // 누른 기사의 key
    public event Action<string>? BundleInvoked;   // 누른 묶음의 분야
    public event Action<string>? SearchInvoked;   // 누른 지켜볼 낱말 정리의 낱말(N-27)

    public void Register()
    {
        if (registered) return;
        try
        {
            AppNotificationManager.Default.NotificationInvoked += (_, e) =>
            {
                if (e.Arguments.TryGetValue("key", out var key)) Invoked?.Invoke(key);
                else if (e.Arguments.TryGetValue("section", out var sec)) BundleInvoked?.Invoke(sec);
                else if (e.Arguments.TryGetValue("search", out var w)) SearchInvoked?.Invoke(w);
            };
            AppNotificationManager.Default.Register();
            registered = true;
        }
        catch { registered = false; }
    }

    public void Unregister()
    {
        try { if (registered) AppNotificationManager.Default.Unregister(); } catch { }
    }

    public void Post(IReadOnlyList<NewsItem> items, bool sound)
    {
        Register();
        if (!registered) return;
        foreach (var it in items.Take(3))
        {
            var b = new AppNotificationBuilder()
                .AddArgument("key", it.Key)
                .AddText($"{it.SourceName} · {Resources.TierLabel(it.Tier)}")
                .AddText(it.TitleKo is { } ko ? $"{ko}\n{it.Title}" : it.Title);
            if (!sound) b.MuteAudio();
            Show(b.BuildNotification());
        }
        if (items.Count > 3)
        {
            var more = new AppNotificationBuilder()
                .AddText(Strings.MoreNews(items.Count - 3))
                .AddText("트레이 아이콘에서 볼 수 있습니다.")
                .MuteAudio();
            Show(more.BuildNotification());
        }
    }

    // 묶음(G-07): "경제 7건" + 제목 3줄, 누르면 매거진의 그 분야 지면
    public void PostBundle(string section, IReadOnlyList<NewsItem> items, bool sound)
    {
        Register();
        if (!registered || items.Count == 0) return;
        var b = new AppNotificationBuilder()
            .AddArgument("section", section)
            .AddText(Strings.Bundle(section, items.Count))
            .AddText(string.Join("\n", items.Take(3).Select(i => i.DisplayTitle)));
        if (!sound) b.MuteAudio();
        Show(b.BuildNotification());
    }

    // 지켜볼 낱말 하루 정리(N-27): "오늘 ○○ 소식 3건" + 제목 2줄, 누르면 매거진 검색
    public void PostWatch(string word, IReadOnlyList<NewsItem> items, bool sound)
    {
        Register();
        if (!registered || items.Count == 0) return;
        var b = new AppNotificationBuilder()
            .AddArgument("search", word)
            .AddText(Strings.Watch(word, items.Count))
            .AddText(string.Join("\n", items.Take(2).Select(i => i.DisplayTitle)));
        if (!sound) b.MuteAudio();
        Show(b.BuildNotification());
    }

    private static void Show(AppNotification n)
    {
        try { AppNotificationManager.Default.Show(n); } catch { }
    }
}
