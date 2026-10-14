using System.Text.Json.Nodes;
using Dropcap.Core;

namespace Dropcap.Ui;

// 설정 창(P 절·K 절·G-13). 맥 SettingsView 와 같은 탭(일반·분야·구독·거르기), 같은 문구·선택지.
public sealed class SettingsPage(AppModel model, IPlatform platform, Scrapbook? scrapbook = null) : IPage
{
    public string Name => "settings";

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
    public object SourceRow(Source s, bool removable)
    {
        var enabled = model.State.Enabled.GetValueOrDefault(s.Id);
        var notify = model.Notifies(s.Id);
        return new
        {
            id = s.Id,
            name = s.Name,
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
                // P-02: 윈도우에는 무료 기기 내 번역이 없어 Google 번역만(T-05 ⊘)
                translation = Translator.EngineGoogle,
                translationNote = "윈도우에는 무료로 쓸 수 있는 기기 내 번역이 없어 Google 번역을 씁니다.",
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
                await Summarizer.AvailableAsync(); // P-04: Ollama 가 켜져 있는지(1.5초 안에)
                return View();
            case "view": return View();
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
            case "onboarding": platform.OpenOnboarding(); return null;
            case "magazine": platform.OpenMagazine(); return null;
            case "close": platform.CloseWindow(Name); return null;
            default: throw new InvalidOperationException("모르는 명령 " + cmd);
        }
    }
}
