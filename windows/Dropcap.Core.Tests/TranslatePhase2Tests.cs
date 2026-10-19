namespace Dropcap.Core.Tests;

// 번역 2단계(맥 TranslatePhase2Tests 와 같은 꼴): 네트워크 없이 엔진 부르기를 가짜로 바꿔 끼운다.
// 윈도우엔 기기 내 번역이 없어 흘려 주기(케이스 5)·기기 내만 시험은 없다. 방식이 바뀌면 캐시 비우기는 TranslateOffTests.
public class TranslatePhase2Tests
{
    private readonly List<string> sent = new();

    // 묶음(빈 줄로 이은 글)을 문단마다 "번역: " 을 붙여 돌려주는 구글. shift 면 문단 수는 같고 한 칸 밀림
    private Translator T(bool shift = false) => new()
    {
        ModeSource = () => "google",
        Backend = (text, _) =>
        {
            lock (sent) sent.Add(text);
            var parts = text.Split("\n\n").Select(p => "번역: " + p).ToList();
            if (shift && parts.Count > 1) parts = [.. parts.Skip(1), parts[0]];
            return Task.FromResult<string?>(string.Join("\n\n", parts));
        },
    };

    // MARK: 케이스 8 — 글자 없는·주소만 블록
    [Fact]
    public void NoLetterOrUrlOnlyIsNotForeign()
    {
        Assert.False(Translator.LooksForeign("16"));
        Assert.False(Translator.LooksForeign("01 /"));
        Assert.False(Translator.LooksForeign("|"));
        Assert.False(Translator.LooksForeign("https://blogs.example.com/wp-content/uploads/2026/10/demo_4k.mp4"));
        Assert.False(Translator.LooksForeign("  www.example.com/a  "));
        Assert.True(Translator.LooksForeign("GPT-5"));
        Assert.True(Translator.LooksForeign("See https://example.com for details"));
        Assert.True(Translator.LooksForeign("OpenAI releases a new model"));
    }

    [Fact]
    public async Task NoLetterBlocksAreNotSent()
    {
        var r = await T().TranslateManyReportingAsync(["2026", "https://example.com/video.mp4", "Hello world"]);
        Assert.Equal(["2026", "https://example.com/video.mp4", "번역: Hello world"], r.Texts);
        Assert.Equal(["Hello world"], sent);
    }

    // MARK: 케이스 3 — 제목 끝 마침표
    [Fact]
    public void TitlePeriodDropped()
    {
        Assert.Equal("Sophos는 위협 조사 시간을 96% 단축했습니다", Translator.Polish("Sophos cuts threat investigation time by 96%", "Sophos는 위협 조사 시간을 96% 단축했습니다."));
        Assert.Equal("작동합니다.", Translator.Polish("It works.", "작동합니다."));
        Assert.Equal("기다려...", Translator.Polish("Wait for it", "기다려..."));
        Assert.Equal("진짜입니까?", Translator.Polish("Is it real?", "진짜입니까?"));
    }

    // 번역 결과에 다듬기가 실제로 적용된다(제목은 묶음 첫 문단으로 감)
    [Fact]
    public async Task PolishAppliedToResults()
    {
        var t = new Translator { ModeSource = () => "google", Backend = (_, _) => Task.FromResult<string?>("클로드 군단을 소개합니다.") };
        Assert.Equal("Claude Corps을 소개합니다", await t.TranslateAsync("Introducing Claude Corps"));
    }

    // MARK: 케이스 2 — 이름 되돌림
    [Fact]
    public void NamesRestoredOnlyWhenInSource()
    {
        Assert.Equal("Claude Corps을 소개합니다", Translator.RestoreNames("Introducing Claude Corps", "클로드 군단을 소개합니다"));
        Assert.Equal("실제로 Claude를 어떻게 사용하는지", Translator.RestoreNames("how people actually use Claude in these contexts", "실제로 클도를 어떻게 사용하는지"));
        Assert.Equal("Claude Opus 5.5는 99%를 받았다", Translator.RestoreNames("Claude Opus 5.5 scored 99%", "클로드 Opus 5.5는 99%를 받았다"));
        // 원문에 영문 이름이 없으면 건드리지 않는다
        Assert.Equal("클로드는 수련을 좋아했다", Translator.RestoreNames("The painter loved water lilies", "클로드는 수련을 좋아했다"));
        // 사람 이름(Claude 뒤에 제품 낱말이 아닌 대문자 낱말)이면 건드리지 않는다
        Assert.Equal("클로드 모네가 그렸다", Translator.RestoreNames("Claude Monet painted it", "클로드 모네가 그렸다"));
        Assert.Equal("Copilot가 이제 시험을 작성합니다", Translator.RestoreNames("Copilot now writes tests", "부조종사가 이제 시험을 작성합니다"));
        // 낱말 안에 든 것은 아님(예: Claudette)
        Assert.Equal("클로드가 말했다", Translator.RestoreNames("Claudette said", "클로드가 말했다"));
    }

    // MARK: 케이스 10 — 묶음 대조
    [Fact]
    public void ShiftDetection()
    {
        string[] src = ["Claude uses 250,000 conversations", "Democracy Works runs TurboVote", "NASA names a deputy in 2023"];
        string[] ok = ["Claude는 25만 건의 대화를 씁니다", "Democracy Works는 TurboVote를 운영합니다", "NASA는 2023년 부국장을 임명합니다"];
        Assert.False(Translator.LooksShifted(src, ok));
        Assert.True(Translator.LooksShifted(src, [ok[1], ok[2], ok[0]]));
        // 숫자를 한국식으로 바꾸거나 영문 낱말이 없는 문단은 밀림으로 보지 않는다
        Assert.False(Translator.LooksShifted(["It cost $150 million", "Nothing to anchor here"], ["1억 5천만 달러가 들었다", "여기엔 기준이 없다"]));
    }

    [Fact]
    public async Task ShiftedBatchRetriedPerParagraph()
    {
        string[] src = ["Alpha news from OpenAI", "Beta update from NVIDIA", "Gamma report by NASA"];
        var r = await T(shift: true).TranslateManyReportingAsync(src);
        Assert.Equal(src.Select(s => "번역: " + s), r.Texts);   // 문단별로 다시 받아 제자리
        Assert.Equal(1 + src.Length, sent.Count);
    }
}
