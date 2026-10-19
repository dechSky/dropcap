using System.Text.Json.Nodes;
using Dropcap.Core;

namespace Dropcap.Ui;

// 설정 창(P 절·K 절·G-13·I-05·I-06). 맥 SettingsView 와 같은 탭(일반·분야·구독·거르기·스크랩북), 같은 문구·선택지.
public sealed class SettingsPage(AppModel model, IPlatform platform, Scrapbook? scrapbook = null, ScrapExport? export = null) : IPage
{
    public string Name => "settings";

    // 스크랩북 탭(I-06): 노트 폴더 내보내기. 따로 주지 않으면 앱 전체의 것(설정만 그릴 때는 DB 를 열지 않음)
    private ScrapExport Export => export ?? ScrapExport.Shared;

    // 내 기록 내보내기·가져오기(P-08): 마지막 결과 문구(화면 아래에 보임)
    private string? backupMessage;
    private Scrapbook Book => scrapbook ?? Scrapbook.Shared;

    // 시각 선택지: 방해 금지는 0~23시, 아침 브리핑은 오전 5시~낮 12시(C-19·C-21)
    public static readonly int[] DigestHours = [5, 6, 7, 8, 9, 10, 11, 12];
    public static string HourLabel(int h) => $"{h:00}:00";
    public static string DigestLabel(int h) => h == 12 ? "낮 12시" : $"오전 {h}시";

    // 분야 탭(G-13): 묶음 시각은 6~23시, 분야 하루 상한은 1~10번
    public const int BundleFrom = SettingsBounds.BundleFrom, BundleTo = SettingsBounds.BundleTo, CapMin = SettingsBounds.CapMin, CapMax = SettingsBounds.CapMax;

    // 알림 양(맥 Stepper 와 같은 범위). 키는 set 명령의 key
    public static readonly (string Key, int Min, int Max)[] Limits =
        [("totalDailyCap", 1, 30), ("krThreshold", 1, 10), ("intlThreshold", 1, 10), ("bigThreshold", 2, 20)];
    private static string LimitLabel(string key, int n) => key switch
    {
        "totalDailyCap" => $"하루 전체 물방울 {n}번까지",
        "krThreshold" => $"국내 {n}곳 이상 보도면 중요",
        "intlThreshold" => $"해외 {n}곳 이상 보도면 중요",
        _ => $"국내 {n}곳 이상이면 상한을 넘어도 알림",
    };
    private int LimitValue(string key)
    {
        var st = model.State.Settings;
        return key switch { "totalDailyCap" => st.TotalDailyCap, "krThreshold" => st.KrThreshold, "intlThreshold" => st.IntlThreshold, _ => st.BigThreshold };
    }

    // 단축키 안내(설정 › 거르기 › 단축키, 맥 NavKey.help — ⌘ 는 Ctrl)
    public static readonly (string Keys, string Label)[] NavKeys =
    [
        ("↓ / J · ↑ / K", "다음·이전 소식 고르기 (트레이 창 목록·매거진 카드)"),
        ("Enter", "고른 소식 열기"),
        ("S", "나중에 읽기 / 저장 취소"),
        ("O", "브라우저에서 열기"),
        ("M", "읽음 / 안 읽음"),
        ("Ctrl+[ · Ctrl+]", "매거진 이전·다음 지면"),
        ("J · K (읽기 창)", "같은 목록의 다음·이전 기사"),
        ("Esc (읽기 창)", "창 닫기"),
        ("Ctrl+,", "설정 열기 (매거진·읽기 창)"),
    ];

    // 쉼표·줄바꿈으로 나눠 앞뒤 빈칸을 지우고 빈 낱말은 버린다(맥 saveKeywords 와 같음)
    public static List<string> SplitKeywords(string text) =>
        text.Split([',', '\n'], StringSplitOptions.None).Select(w => w.Trim()).Where(w => w.Length > 0).ToList();

    // 글자 원형: 기본·직접 추가 출처는 "The " 를 뺀 첫 글자, 추천 채널은 이름 첫 글자(맥과 같음)
    private static string Letter(string name, bool dropThe)
    {
        var n = dropThe ? name.Replace("The ", "") : name;
        return n.Length == 0 ? "" : n[..1].ToUpperInvariant();
    }

    // 기본 출처·구독 중인 채널 한 줄
    // 번역 방식 고르기(W4 · 맥과 같은 값). 윈도우엔 기기 내 번역이 없어 '기기 내'는 맥에서 가져온 값일 때만 보인다(그때는 번역하지 않음)
    public sealed record EngineOption(string Id, string Label);
    public static List<EngineOption> TranslateEngines(string current)
    {
        var o = new List<EngineOption> { new("auto", "자동 (Google 번역)"), new("google", "Google 번역"), new("off", "번역 안 함") };
        if (current == "apple") o.Insert(1, new("apple", "기기 내 번역 (이 PC 에는 없어 번역하지 않음)"));
        return o;
    }

    // 유료 자물쇠 설명(맥 sourceRow 와 같은 문구). 없거나 모르는 값이면 무료로 봄
    public static string? PaywallHelp(string? paywall) => paywall switch
    {
        "hard" => "구독해야 읽을 수 있음",
        "metered" => "한 달 몇 건 무료",
        _ => null,
    };

    // media: 매체 묶음 안에서 그릴 때 매체 이름(짧은 이름을 위해). 분야 칩·국내/해외·유료 자물쇠는 설정 › 구독 정리(SourceDirectory)
    public object SourceRow(Source s, bool removable, string? media = null)
    {
        var enabled = model.State.Enabled.GetValueOrDefault(s.Id);
        var notify = model.Notifies(s.Id);
        var paywallHelp = PaywallHelp(s.Paywall);
        return new
        {
            id = s.Id,
            name = s.Name,
            shortName = media is null ? s.Name : SourceDirectory.ShortName(s, media),
            section = s.SectionId,
            sectionName = Sections.Name(s.SectionId),
            region = SourceDirectory.RegionLabel(s),
            paywall = paywallHelp is null ? null : s.Paywall,
            paywallHelp,
            initial = Letter(s.Name, dropThe: true),
            color = ItemView.SafeColor(s.Color),
            kind = s.ItemKind.Raw(),
            kindLabel = s.ItemKind == ItemKind.Article ? null : s.ItemKind.Label(),
            aiOnly = s.AiOnly,
            error = model.State.Errors.TryGetValue(s.Id, out var e) ? $"확인 실패: {e}" : null,
            sub = s.Home ?? (removable ? s.Url : null),
            enabled,
            notify,
            notifyHelp = notify ? "새 글 알림 켜짐 (끄면 매거진에만 실림)" : "알림 꺼짐 — 매거진에만 실림",
            removable,
        };
    }

    // 추천 채널 한 줄(구독/구독 중)
    public object CatalogRow(Source s) => new
    {
        id = s.Id,
        name = s.Name,
        initial = Letter(s.Name, dropThe: false),
        color = ItemView.SafeColor(s.Color),
        kind = s.ItemKind.Raw(),
        kindLabel = s.ItemKind == ItemKind.Article ? null : s.ItemKind.Label(),
        sub = s.NotifyDefault == false ? "글이 많아 알림 없이 매거진에만 실림" : "새 글이 오면 알림",
        subscribed = model.IsSubscribed(s),
        subscribing = model.Subscribing.Contains(s.Url),
    };

    // 고른 분야 한 칸(맥 sectionRow)
    public object SectionRow(NewsSection s)
    {
        var p = model.Policy(s.Id);
        var (on, all) = model.SourceCount(s.Id);
        return new
        {
            id = s.Id,
            name = s.Name,
            icon = s.Icon,
            color = ItemView.SafeColor(s.Color),
            sub = s.IsFlow ? "어느 분야든 크게 다룬 소식" : all > 0 ? $"출처 {on}/{all}곳 켜짐" : "구독 탭에서 출처를 켜고 끕니다",
            sourcesOn = on,
            sourcesAll = all,
            mode = p.Mode.Raw(),
            modeHelp = p.Mode.Help(),
            bundleHour = p.BundleHour,
            bundleHelp = p.Mode == NotifyMode.Instant ? "하루 상한을 넘어 고인 소식을 보내는 시각" : "모아 둔 소식을 한 방울로 보내는 시각",
            dailyCap = p.DailyCap,
            capLabel = $"하루 {p.DailyCap}번까지",
        };
    }

    // 숨긴 출처 이름: sources.json → 지금 출처 목록 → id
    private string HiddenName(string id) =>
        Sections.Meta.GetValueOrDefault(id)?.Name ?? model.AllSources.FirstOrDefault(s => s.Id == id)?.Name ?? id;

    public object SectionsView()
    {
        var chosen = model.ChosenSections;
        return new
        {
            summary = chosen.Count == 0 ? "아직 관심 분야를 고르지 않았습니다" : $"고른 분야 {chosen.Count(id => id != Sections.Top)}개",
            rows = Sections.All.Where(s => chosen.Contains(s.Id)).Select(SectionRow).ToList(),
            modes = NotifyModes.All.Select(m => new { id = m.Raw(), label = m.Label(), help = m.Help() }).ToList(),
            bundleHours = Enumerable.Range(BundleFrom, BundleTo - BundleFrom + 1).Select(h => new { value = h, label = HourLabel(h) }).ToList(),
            capMin = CapMin,
            capMax = CapMax,
            limits = Limits.Select(l => new { key = l.Key, label = LimitLabel(l.Key, LimitValue(l.Key)), value = LimitValue(l.Key), min = l.Min, max = l.Max }).ToList(),
            hidden = model.State.HiddenSources.Select(id => new { id, name = HiddenName(id) }).ToList(),
        };
    }

    // 설정 › 스크랩북(맥 ScrapbookSettingsView): 노트 폴더로 내보내기 · 아무 웹 주소나 나중에 읽기로
    public object ScrapbookView()
    {
        var x = Export;
        var folder = x.Folder;
        var saved = x.SavedPath;
        return new
        {
            enabled = x.Enabled && folder is not null,
            folder = folder ?? (saved is { Length: > 0 } p ? $"{p} (찾지 못함)" : "고르지 않음"),
            hasFolder = folder is not null,
            choose = folder is null ? "고르기…" : "바꾸기…",
            error = x.LastError,
            canSaveNow = x.Enabled && folder is not null && x.HasScraps,
            exportNote = "스크랩 폴더마다 ‘폴더 이름.md’ 파일 하나 — Obsidian 보관소 안의 폴더를 고르면 노트로 바로 보입니다. 파일은 덮어쓰니 고쳐 쓸 노트는 다른 이름으로 두세요.",
            addUrl = "‘저장’ 목록 위 ‘주소로 추가…’ 칸에 붙여 넣기",
            bookmarkletNote = "새 북마크를 만들고 주소 칸에 복사한 코드를 붙여 넣으세요. 기사를 보다 그 북마크를 누르면 Dropcap 의 나중에 읽기에 담깁니다. "
                + "다른 프로그램에서는 dropcap://save?url=<주소> 를 열거나 Dropcap.exe --save <주소> 로 부르면 됩니다.",
        };
    }

    // 설정 › 구독 정리(SourceDirectory): 찾기·상태는 창이 열려 있는 동안만, 보기(매체별·분야별·지역별)는 기억(prefs)
    public const string LayoutKey = "sourceLayout";
    private string sourceQuery = "";
    private SourceDirectory.Status sourceStatus = SourceDirectory.Status.All;
    public SourceDirectory.Layout SourceLayout => SourceDirectory.ParseLayout(Prefs.Get(LayoutKey, "media")) ?? SourceDirectory.Layout.Media;

    // view·ready 가 함께 보낸 찾기·보기·상태를 받는다(보내지 않은 것은 그대로). 모르는 값은 오류
    public void ApplyDirectory(JsonObject a)
    {
        if (a.ContainsKey("query")) sourceQuery = a.Str("query");
        if (a.ContainsKey("layout"))
        {
            var l = SourceDirectory.ParseLayout(a.Str("layout")) ?? throw new ArgumentOutOfRangeException("layout");
            if (l != SourceLayout) Prefs.Set(LayoutKey, l.Raw());
        }
        if (a.ContainsKey("status")) sourceStatus = SourceDirectory.ParseStatus(a.Str("status")) ?? throw new ArgumentOutOfRangeException("status");
    }

    public object DirectoryView()
    {
        var all = Resources.Config.Sources;
        var custom = model.State.CustomSources;
        bool On(string id) => model.State.Enabled.GetValueOrDefault(id);
        var layout = SourceLayout;
        var shown = SourceDirectory.Filter(all, sourceQuery, sourceStatus, On);
        var mine = SourceDirectory.Sorted(SourceDirectory.Filter(custom, sourceQuery, sourceStatus, On));
        var catalog = ChannelCatalog.All.Where(s => SourceDirectory.Matches(s, sourceQuery)).ToList();
        var searching = SourceDirectory.Fold(sourceQuery).Length > 0;
        var groups = SourceDirectory.Groups(all, shown, layout, On);
        return new
        {
            query = sourceQuery,
            searching,
            layout = layout.Raw(),
            layouts = SourceDirectory.Layouts.Select(l => new { id = l.Raw(), label = l.Label() }).ToList(),
            status = sourceStatus.Raw(),
            statuses = SourceDirectory.Statuses.Select(x => new { id = x.Raw(), label = x.Label() }).ToList(),
            summary = SourceDirectory.SummaryText(all.Concat(custom), On),
            count = SourceDirectory.CountText(shown.Count + mine.Count, all.Count + custom.Count),
            empty = shown.Count == 0 && mine.Count == 0 && catalog.Count == 0,
            emptyText = "찾는 출처가 없습니다. 이름·주소를 다시 확인하거나 위 '채널 추가'에 주소를 넣어 보세요.",
            // 내 채널: 걸린 것이 있거나, 거르지 않을 때(비어 있으면 안내)
            mine = new
            {
                show = mine.Count > 0 || (!searching && sourceStatus == SourceDirectory.Status.All),
                label = $"내 채널 {custom.Count}",
                rows = mine.Select(s => SourceRow(s, removable: true)).ToList(),
            },
            groups = groups.Select(g =>
            {
                var allOn = g.Sources.All(s => On(s.Id));
                var media = layout == SourceDirectory.Layout.Media ? g.Title : null;
                return new
                {
                    id = g.Id,
                    title = g.Title,
                    on = g.On,
                    total = g.Total,
                    countLabel = $"{g.On}/{g.Total} 켬",
                    single = layout == SourceDirectory.Layout.Media && g.Total == 1, // 피드가 하나뿐인 매체는 묶음 없이 그냥 줄
                    allOn,
                    bulk = allOn ? "모두 끄기" : "모두 켜기",
                    bulkHelp = g.Sources.Count < g.Total ? $"보이는 {g.Sources.Count}곳에만" : $"이 묶음 {g.Total}곳 모두",
                    ids = g.Sources.Select(s => s.Id).ToList(), // 묶음 켜기·끄기는 보이는(거른) 것에만
                    initial = Letter(g.Title, dropThe: true),
                    color = ItemView.SafeColor(g.Sources[0].Color),
                    rows = g.Sources.Select(s => SourceRow(s, removable: false, media)).ToList(),
                };
            }).ToList(),
            // 추천 채널: 맨 아래 접힌 묶음(찾기 적용, 찾는 중이면 펼침)
            recommended = new
            {
                label = $"추천 채널 {catalog.Count}",
                count = catalog.Count,
                groups = ChannelCatalog.Groups
                    .Select(g => new { label = g, rows = catalog.Where(s => s.Group == g).Select(CatalogRow).ToList() })
                    .Where(g => g.rows.Count > 0).ToList(),
            },
        };
    }

    public object View()
    {
        var st = model.State.Settings;
        string[] tiers = ["lab", "press", "kr"];
        return new
        {
            general = new
            {
                style = st.Style == ToastStyle.System ? "system" : "drop",
                styles = new[] { new { id = "drop", label = "물방울 (앱이 직접 그림)" }, new { id = "system", label = "시스템 알림 센터" } },
                position = st.Position == ToastPosition.Right ? "right" : "center",
                positions = new[] { new { id = "center", label = "위쪽 가운데" }, new { id = "right", label = "오른쪽 위" } },
                sound = st.Sound,
                interval = st.IntervalMinutes,
                intervals = StateSettings.Intervals.Select(m => new { value = m, label = $"{m}분" }).ToList(),
                // P-02: 번역 엔진 고르기(W4). 윈도우에는 무료 기기 내 번역이 없어 자동 = Google 번역(T-05 ⊘)
                translateEngine = st.TranslateEngine,
                translateEngines = TranslateEngines(st.TranslateEngine),
                translationNote = "번역을 켜 두면 Google 번역으로 본문 문단이 전송됩니다(외국어 기사 제목·같은 소식 묶기용 영어 번역 포함). "
                                + "윈도우에는 무료로 쓸 수 있는 기기 내 번역이 없습니다. '번역 안 함'이면 아무것도 보내지 않고 원문을 보여 줍니다.",
                pretendard = Prefs.Get("usePretendard", true),
                // P-04: ready 때 Ollama 를 한 번 찾아본 결과
                summary = Summarizer.Status,
                summaryOn = Summarizer.Model is not null,
                launchAtLogin = platform.LaunchAtLogin,
                // 회의·발표 중에는 조용히(N-25). 캘린더는 윈도우에서 쓸 수 없어 꺼 두고 이유를 보인다
                autoQuietFullscreen = st.AutoQuietFullscreen,
                autoQuietSharing = st.AutoQuietSharing,
                autoQuietCalendar = st.AutoQuietCalendar && model.Focus.CalendarSupported,
                calendarSupported = model.Focus.CalendarSupported,
                autoQuietNote = "이때 온 소식은 물방울 없이 '안 읽음'에 쌓이고, 알릴 만한 소식은 그 분야 묶음으로 모입니다. "
                    + "전체 화면은 다른 앱이 화면을 통째로 덮을 때(전체 화면·발표·게임), 화면 공유는 Zoom 화면 공유를 알아봅니다. "
                    + "Teams·Meet 처럼 브라우저로 하는 공유는 알 수 없어 전체 화면일 때만 조용해집니다.",
                calendarNote = model.Focus.CalendarSupported ? null : "윈도우 판은 설치 없이 푸는 앱이라 윈도우 캘린더(일정) 권한을 받을 수 없어 쓸 수 없습니다.",
                // 내 기록(P-08) — 맥과 같은 파일 형식이라 Mac·리눅스와 옮길 수 있음
                backup = new
                {
                    intro = "계정도 서버도 없습니다. 모든 기록은 이 PC 안에만 있습니다.",
                    note = "다른 PC·Mac 으로 옮길 때: 저장·스크랩과 폴더·구독·분야·알림 설정·낱말·숨긴 출처를 JSON 파일 하나로 내보내고, 다른 기기에서 가져오면 없는 것만 더합니다(같은 것은 건너뜀). 기사 캐시·사진은 담지 않습니다. 가져오기 전 기록은 자동으로 남겨 되돌릴 수 있습니다.",
                    canUndo = Backup.CanUndo,
                    message = backupMessage,
                },
            },
            sections = SectionsView(),
            scrapbook = ScrapbookView(),
            sources = new
            {
                custom = model.State.CustomSources.Select(s => SourceRow(s, removable: true)).ToList(),
                tiers = tiers.Select(t => new
                {
                    label = $"기본 출처 · {Resources.TierLabel(t)}",
                    rows = Resources.Config.Sources.Where(s => s.Tier == t).Select(s => SourceRow(s, removable: false)).ToList(),
                }).ToList(),
                catalog = ChannelCatalog.Groups.Select(g => new
                {
                    label = $"추천 · {g}",
                    rows = ChannelCatalog.All.Where(s => s.Group == g).Select(CatalogRow).ToList(),
                }).ToList(),
                directory = DirectoryView(),   // 설정 › 구독 정리: 찾기·보기·상태가 반영된 목록(화면은 이것을 그림)
            },
            filters = new
            {
                must = string.Join(", ", st.MustKeywords),
                mute = string.Join(", ", st.MuteKeywords),
                watch = string.Join(", ", st.WatchKeywords),   // 지켜볼 낱말(N-27)
                quietEnabled = st.QuietEnabled,
                quietStart = st.QuietStart,
                quietEnd = st.QuietEnd,
                hours = Enumerable.Range(0, 24).Select(h => new { value = h, label = HourLabel(h) }).ToList(),
                digestEnabled = st.DigestEnabled,
                digestHour = st.DigestHour,
                digestHours = DigestHours.Select(h => new { value = h, label = DigestLabel(h) }).ToList(),
                hotkeys = new[]
                {
                    new { label = "가장 최근 안 읽은 소식 열기", keys = "Ctrl+Alt+N" },
                    new { label = $"{Strings.Magazine} 열기", keys = "Ctrl+Alt+M" },
                },
                navKeys = NavKeys.Select(k => new { keys = k.Keys, label = k.Label }).ToList(), // H-03~H-05
            },
        };
    }

    // 설정 값 하나 바꾸기. 모르는 키·범위 밖 값은 오류(화면이 잘못 보낸 값을 그대로 저장하지 않게)
    public void Set(string key, JsonObject a)
    {
        int Hour(int lo, int hi) // 범위 안의 정수(시각·횟수)
        {
            var h = a.Int("value", -1);
            return h >= lo && h <= hi ? h : throw new ArgumentOutOfRangeException(key);
        }
        switch (key)
        {
            case "style":
                var style = a.Str("value") switch { "drop" => ToastStyle.Drop, "system" => ToastStyle.System, _ => throw new ArgumentOutOfRangeException(key) };
                model.Update(s => s.Style = style);
                break;
            case "position":
                var pos = a.Str("value") switch { "center" => ToastPosition.Center, "right" => ToastPosition.Right, _ => throw new ArgumentOutOfRangeException(key) };
                model.Update(s => s.Position = pos);
                break;
            case "translateEngine":
                var te = a.Str("value");
                if (!TranslateEngines(model.State.Settings.TranslateEngine).Any(o => o.Id == te)) throw new ArgumentOutOfRangeException(key);
                model.Update(s => s.TranslateEngine = te);
                break;
            case "sound": var sound = a.Bool("value"); model.Update(s => s.Sound = sound); break;
            case "interval":
                var m = a.Int("value");
                if (!StateSettings.Intervals.Contains(m)) throw new ArgumentOutOfRangeException(key);
                model.Update(s => s.IntervalMinutes = m);
                break;
            case "quietEnabled": var q = a.Bool("value"); model.Update(s => s.QuietEnabled = q); break;
            case "quietStart": var qs = Hour(0, 23); model.Update(s => s.QuietStart = qs); break;
            case "quietEnd": var qe = Hour(0, 23); model.Update(s => s.QuietEnd = qe); break;
            case "digestEnabled": var d = a.Bool("value"); model.Update(s => s.DigestEnabled = d); break;
            case "digestHour": var dh = Hour(DigestHours[0], DigestHours[^1]); model.Update(s => s.DigestHour = dh); break;
            case "pretendard": Prefs.Set("usePretendard", a.Bool("value")); platform.ApplyFont(); break; // P-03
            case "launchAtLogin": platform.LaunchAtLogin = a.Bool("value"); break;                          // P-05
            // N-25 회의·발표 중에는 조용히. 캘린더는 지원할 때만 켤 수 있다
            case "autoQuietFullscreen": var af = a.Bool("value"); model.Update(s => s.AutoQuietFullscreen = af); break;
            case "autoQuietSharing": var asr = a.Bool("value"); model.Update(s => s.AutoQuietSharing = asr); break;
            case "autoQuietCalendar":
                var ac = a.Bool("value") && model.Focus.CalendarSupported;
                model.Update(s => s.AutoQuietCalendar = ac);
                break;
            // G-13 알림 양: 전체 상한·문턱
            case "totalDailyCap" or "krThreshold" or "intlThreshold" or "bigThreshold":
                var (_, min, max) = Limits.First(l => l.Key == key);
                var n = Hour(min, max);
                model.Update(s =>
                {
                    switch (key)
                    {
                        case "totalDailyCap": s.TotalDailyCap = n; break;
                        case "krThreshold": s.KrThreshold = n; break;
                        case "intlThreshold": s.IntlThreshold = n; break;
                        default: s.BigThreshold = n; break;
                    }
                });
                break;
            default: throw new InvalidOperationException("모르는 설정 " + key);
        }
    }

    // 분야 하나의 알림 정책 바꾸기(G-13). 모르는 분야·범위 밖 값은 오류
    public void SetPolicy(string section, string key, JsonObject a)
    {
        if (Sections.ById(section) is null) throw new KeyNotFoundException("분야를 찾지 못함");
        switch (key)
        {
            case "mode":
                var mode = NotifyModes.All.Where(m => m.Raw() == a.Str("value")).Cast<NotifyMode?>().FirstOrDefault()
                    ?? throw new ArgumentOutOfRangeException(key);
                model.SetPolicy(section, p => p with { Mode = mode });
                break;
            case "bundleHour":
                var h = a.Int("value", -1);
                if (h < BundleFrom || h > BundleTo) throw new ArgumentOutOfRangeException(key);
                model.SetPolicy(section, p => p with { BundleHour = h });
                break;
            case "dailyCap":
                var c = a.Int("value", -1);
                if (c < CapMin || c > CapMax) throw new ArgumentOutOfRangeException(key);
                model.SetPolicy(section, p => p with { DailyCap = c });
                break;
            default: throw new InvalidOperationException("모르는 분야 설정 " + key);
        }
    }

    private Source Known(string id) =>
        model.AllSources.FirstOrDefault(s => s.Id == id) ?? throw new KeyNotFoundException("출처를 찾지 못함");

    public async Task<object?> Handle(string cmd, JsonObject a)
    {
        switch (cmd)
        {
            case "ready":
                ApplyDirectory(a);
                await Summarizer.AvailableAsync(); // P-04: Ollama 가 켜져 있는지(1.5초 안에)
                return View();
            case "view": ApplyDirectory(a); return View();
            case "set": Set(a.Str("key"), a); return null;
            case "keywords":
                var must = SplitKeywords(a.Str("must"));
                var mute = SplitKeywords(a.Str("mute"));
                var watch = WatchWords.Normalized(SplitKeywords(a.Str("watch")));
                // 바뀐 것이 있을 때만 저장하고, 이미 받은 목록에도 바로 적용(★ 다시 매기기·알리지 않음 낱말 빼기)
                if (!must.SequenceEqual(model.State.Settings.MustKeywords) || !mute.SequenceEqual(model.State.Settings.MuteKeywords)
                    || !watch.SequenceEqual(model.State.Settings.WatchKeywords))
                {
                    model.Update(s => { s.MustKeywords = must; s.MuteKeywords = mute; s.WatchKeywords = watch; });
                    model.ReapplyKeywords();
                }
                return new { must = string.Join(", ", must), mute = string.Join(", ", mute), watch = string.Join(", ", watch) };
            case "preview": model.Preview(); return null;
            // K-02: 주소로 구독. 실패하면 이유를 돌려준다(K-04)
            case "addChannel":
                var input = a.Str("input").Trim();
                if (input.Length == 0) return new { error = "주소를 넣어 주세요" };
                return new { error = await model.AddChannelAsync(input, a.Str("name")) };
            case "subscribe":
                var src = ChannelCatalog.All.FirstOrDefault(s => s.Id == a.Str("id")) ?? throw new KeyNotFoundException("추천 채널을 찾지 못함");
                return new { error = await model.SubscribeAsync(src) };
            case "remove":
                if (!model.State.CustomSources.Any(s => s.Id == a.Str("id"))) throw new KeyNotFoundException("구독 중인 채널이 아님");
                model.RemoveCustomSource(a.Str("id"));
                return null;
            case "setNotify": model.SetNotify(Known(a.Str("id")).Id, a.Bool("on")); return null;
            case "setEnabled": model.SetEnabled(Known(a.Str("id")).Id, a.Bool("on")); return null;
            // 묶음 모두 켜기·끄기: 모르는 id 가 하나라도 있으면 아무것도 바꾸지 않는다. 저장·확인은 한 번
            case "setEnabledMany":
            {
                var ids = (a["ids"] as JsonArray ?? throw new ArgumentException("ids"))
                    .Select(n => n is JsonValue v && v.TryGetValue<string>(out var id) ? id : throw new ArgumentException("ids")).ToList();
                var known = model.AllSources.Select(x => x.Id).ToHashSet();
                if (ids.Any(id => !known.Contains(id))) throw new KeyNotFoundException("출처를 찾지 못함");
                model.SetEnabled(ids, a.Bool("on"));
                return null;
            }
            // G-13: 분야별 정책·숨긴 출처 되돌리기·관심 분야 다시 고르기
            case "setPolicy": SetPolicy(a.Str("id"), a.Str("key"), a); return null;
            case "unhide":
                if (!model.State.HiddenSources.Contains(a.Str("id"))) throw new KeyNotFoundException("숨긴 출처가 아님");
                model.UnhideSource(a.Str("id"));
                return null;
            // 내 기록 내보내기·가져오기·되돌리기(P-08)
            case "exportBackup":
                if (await platform.SaveJsonFile(Backup.SuggestedFileName, Backup.Export(model, Book))) backupMessage = "내보냈습니다";
                return new { message = backupMessage };
            case "importBackup":
            {
                string? text;
                try { text = await platform.OpenJsonFile(); }
                catch (Exception e) { backupMessage = "가져오지 못했습니다: " + e.Message; return new { message = backupMessage }; }
                if (text is null) return new { message = backupMessage };
                backupMessage = Backup.Import(text, model, Book).Message;
                return new { message = backupMessage };
            }
            case "undoImport":
                backupMessage = Backup.UndoLastImport(model, Book).Message;
                return new { message = backupMessage };
            // 스크랩북 탭(I-05·I-06)
            case "scrapExport": await Export.Toggle(a.Bool("on")); return null;
            case "chooseScrapFolder": await Export.ChooseFolder(); return null;
            case "forgetScrapFolder": Export.ForgetFolder(); return null;
            case "scrapExportNow": await Task.Run(Export.SyncNow); return null;
            case "copyBookmarklet": platform.CopyText(SaveLink.Bookmarklet); return null;
            case "onboarding": platform.OpenOnboarding(); return null;
            case "magazine": platform.OpenMagazine(); return null;
            case "close": platform.CloseWindow(Name); return null;
            default: throw new InvalidOperationException("모르는 명령 " + cmd);
        }
    }
}
