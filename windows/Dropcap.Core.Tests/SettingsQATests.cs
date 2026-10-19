using Dropcap.Core;

namespace Dropcap.Core.Tests;

// 설정이 실제 동작에 반영되는지(맥 SettingsQATests 와 같은 표)
public class SettingsQATests
{
    private static AppState.PendingItem Pend(string id, string title, string src, string sec) =>
        new(new NewsItem { Id = id, Title = title, Link = "", Date = DateTimeOffset.Now, SourceId = src, SourceName = src, Tier = "media" }, sec, id, DateTimeOffset.Now);

    // 고인 소식(묶음 대기열)도 설정을 따른다: '알리지 않음' 낱말 · 알림 끈 출처 · '매거진만' 분야는 묶음 시각에 나가지 않음
    [Fact]
    public void PendingFollowsMuteBellAndMagazineOnly()
    {
        var all = new[] { Pend("a", "Chip prices rise", "s1", "economy"), Pend("b", "주식 시장 마감", "s1", "economy"),
                          Pend("c", "Rate decision", "s2", "economy"), Pend("d", "Election news", "s1", "politics") };
        var kept = AppModel.PrunePending(all, ["주식"], s => s != "s2", sec => sec == "politics");
        Assert.Equal(["a"], kept.Select(p => p.Item.Id));
        Assert.Equal(4, AppModel.PrunePending(all, [], _ => true, _ => false).Count);
    }
}
