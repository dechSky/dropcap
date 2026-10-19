using Dropcap.Core;
using Dropcap.Ui;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Windows.Graphics;
using static Dropcap.App.Win32;

namespace Dropcap.App;

// 창 관리자: 트레이·트레이 창·설정·매거진·읽기 창·알림 창·전역 단축키를 잇는다.
internal sealed class Shell : IAppUi
{
    public AppModel Model { get; }
    public Bridge Bridge { get; } = new();
    public Magazine Magazine { get; }
    public Scrapbook Scrapbook { get; }
    public ArticleService Articles { get; }

    private readonly DispatcherQueue ui;
    private readonly MessageWindow messages = new();
    private readonly TrayIcon tray;
    private readonly ToastWindow toasts;
    private readonly SystemNotifier system = new();
    private readonly Platform platform;
    private readonly ReaderPage readerPage;
    private readonly MagazinePage magazinePage;

    private RectInt32? pendingFrom;   // 알림 카드를 눌러 연 읽기 창은 그 카드 자리에서 커져 나온다(R-14)
    private WebWindow? menu;
    private DateTime menuHiddenAt;
    private WebWindow? settings;
    private WebWindow? onboarding;
    private WebWindow? magazine;
    // 열린 읽기 창과 지금 보여 주는 기사(J·K 로 같은 창에서 기사가 바뀐다)
    private sealed class ReaderSlot(WebWindow window, string key) { public WebWindow Window { get; } = window; public string Key { get; set; } = key; }
    private readonly List<ReaderSlot> readers = new();

    public const int HotKeyLatest = 1, HotKeyMagazine = 2;

    public Shell(DispatcherQueue ui)
    {
        this.ui = ui;
        Platform.EnsureIcon();
        var db = Database.Shared;
        Magazine = new Magazine(db, retryFile: Path.Combine(Store.Dir, Magazine.RetryFileName));   // 못 넣은 기사는 껐다 켜도 다시 넣게
        Scrapbook = Scrapbook.Shared;
        platform = new Platform(this);
        Model = new AppModel(this, Magazine);
        Articles = new ArticleService(new Extractor(messages.Handle, ui), () => Model.State.Saved.Select(s => s.Link));
        ArticleService.Shared = Articles;
        // 회의·발표 중 자동 조용히(N-25) 감지 · 사진 점수(M-24): 글자 인식은 윈도우 OCR, 표지·분야 사진 고르기에 씀
        Model.Focus.Probe = new FocusProbe();
        PhotoScorer.TextRatio = PhotoOcr.TextRatioAsync;
        ImageTools.Attach(platform);   // 기사 속 사진 도구(R-20): 글자 인식·클립보드·저장 대화상자
        Magazine.PhotoScorer = PhotoScorer.ScoreAsync;
        PaywallBook.Shared = new PaywallBook(db);   // 유료 기사 표시(G-14): 출처별 본문 추리기 기록
        ExternalLink.Opener = u => { _ = Windows.System.Launcher.LaunchUriAsync(u); return true; };

        Bridge.Register(new MenuPage(Model, platform));
        Bridge.Register(new SettingsPage(Model, platform, Scrapbook));
        Bridge.Register(new OnboardingPage(Model, platform, Bridge));   // 분야 사진이 오면 밀어 줌
        readerPage = new ReaderPage(Model, Articles, Scrapbook, platform, Bridge);
        Bridge.Register(readerPage);
        magazinePage = new MagazinePage(Model, Magazine, Scrapbook, platform, Bridge);
        Bridge.Register(magazinePage);
        magazinePage.Attach();

        tray = new TrayIcon(messages);
        tray.Clicked += (x, y) => ToggleMenu();
        toasts = new ToastWindow(Model, ui);
        toasts.Opened += c =>
        {
            if (c.Kind == Ui.Toast.ToastKind.Digest) OpenMagazine(null);
            else if (c.Kind == Ui.Toast.ToastKind.Bundle && c.Section is { } sec) OpenMagazine("section:" + sec);   // 그 분야 지면(G-07)
            else if (c.Kind == Ui.Toast.ToastKind.Watch) OpenMagazine("search:" + c.Title);                          // 그 낱말 검색(N-27)
            else if (c.Item is { } it) { pendingFrom = toasts.CardScreenRect(c); Model.Open(it); pendingFrom = null; }
        };
        system.Invoked += key => ui.TryEnqueue(() =>
        {
            if (Model.State.Recent.FirstOrDefault(i => i.Key == key) is { } it) Model.Open(it);
        });
        system.BundleInvoked += sec => ui.TryEnqueue(() => OpenMagazine("section:" + sec));
        system.SearchInvoked += w => ui.TryEnqueue(() => OpenMagazine("search:" + w));

        // 상태가 바뀌면: 트레이 아이콘(안 읽음), 열린 화면들에 알림
        Model.Changed += () => ui.TryEnqueue(Refresh);
        Magazine.Changed += () => ui.TryEnqueue(() => Bridge.Emit("magazine", "changed"));
        // 미리 받기가 맛보기로 판정함: 목록·카드의 자물쇠를 '앞부분만'으로 다시 그림(물방울은 다음 그리기에서)
        PaywallBook.Shared.TeasersChanged += () => ui.TryEnqueue(Refresh);
        messages.HotKey += OnHotKey;
        messages.Resumed += () => ui.TryEnqueue(Model.OnWake);   // 잠자기에서 깨면 10초 뒤 확인(C-11)
        messages.DisplayChanged += () => ui.TryEnqueue(toasts.Replace);   // 화면 구성이 바뀌면 다시 자리 잡음(N-11)
        messages.SettingChanged += () => ui.TryEnqueue(SendAppearance);
    }

    public void Start()
    {
        tray.Update(Model.State.Unread > 0, Tooltip(), force: true);
        // 전역 단축키(H-01·H-02): Ctrl+Alt+N 가장 최근 안 읽은 소식, Ctrl+Alt+M 매거진
        RegisterHotKey(messages.Handle, HotKeyLatest, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, 'N');
        RegisterHotKey(messages.Handle, HotKeyMagazine, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, 'M');
        if (Model.State.Settings.Style == ToastStyle.System) system.Register();
        Model.Start(SynchronizationContext.Current);
        // 트레이 창을 미리 만들어 두어 누르면 바로 뜨게
        EnsureMenu();
        if (Model.NeedsOnboarding) OpenOnboarding();   // 처음 실행: 관심 분야부터(G-03)
    }

    private void OnHotKey(int id) => ui.TryEnqueue(() =>
    {
        if (id == HotKeyLatest) Model.OpenLatestUnread();
        else if (id == HotKeyMagazine) OpenMagazine(null);
    });

    private string Tooltip() => Model.State.Unread > 0 ? $"Dropcap · 새 소식 {Model.State.Unread}건" : "Dropcap";

    private void Refresh()
    {
        tray.Update(Model.State.Unread > 0, Tooltip());
        Bridge.EmitAll("changed");
    }

    public void SendAppearance()
    {
        foreach (var w in AllWindows()) w.SendAppearance();
    }

    private IEnumerable<WebWindow> AllWindows() =>
        new[] { menu, settings, magazine, onboarding }.OfType<WebWindow>().Concat(readers.Select(r => r.Window));

    // 저장 대화상자·공유 창의 주인: 지금 앞에 있는 우리 창
    public nint OwnerHwnd()
    {
        var fg = GetForegroundWindow();
        return AllWindows().FirstOrDefault(w => w.Hwnd == fg)?.Hwnd ?? magazine?.Hwnd ?? readers.LastOrDefault()?.Window.Hwnd ?? messages.Handle;
    }

    // MARK: 트레이 창(U 절)
    private void EnsureMenu()
    {
        if (menu is not null) return;
        menu = new WebWindow(Bridge, "menu", "", "Dropcap", new SizeInt32(370, 640));
        var p = OverlappedPresenter.Create();
        p.SetBorderAndTitleBar(true, false);
        p.IsResizable = false;
        p.IsMaximizable = false;
        p.IsMinimizable = false;
        p.IsAlwaysOnTop = true;
        menu.AppWindow.SetPresenter(p);
        menu.HideFromTaskbar();
        menu.RoundCorners();
        // 다른 곳을 누르면 닫힌다(맥 상단바 창처럼)
        menu.Window.Activated += (_, e) =>
        {
            if (e.WindowActivationState == Microsoft.UI.Xaml.WindowActivationState.Deactivated) HideMenu();
        };
        menu.Closed += () => menu = null;
    }

    private void HideMenu()
    {
        if (menu is null || !menu.AppWindow.IsVisible) return;
        menu.AppWindow.Hide();
        menuHiddenAt = DateTime.UtcNow;
    }

    public void ToggleMenu()
    {
        EnsureMenu();
        var m = menu!;
        if (m.AppWindow.IsVisible) { HideMenu(); return; }
        // 아이콘을 눌러 닫은 바로 그 클릭으로 다시 열리지 않게
        if ((DateTime.UtcNow - menuHiddenAt).TotalMilliseconds < 250) return;
        var size = m.Scaled(new SizeInt32(370, 640));
        GetCursorPos(out var cur);
        var anchor = tray.Rect() is { } r ? new POINT { X = (r.Left + r.Right) / 2, Y = (r.Top + r.Bottom) / 2 } : cur;
        var (work, mon, scale) = MonitorAt(anchor);
        var gap = (int)(12 * scale);
        int x, y;
        if (work.Bottom < mon.Bottom) { y = work.Bottom - size.Height - gap; x = anchor.X - size.Width / 2; }        // 작업 표시줄이 아래
        else if (work.Top > mon.Top) { y = work.Top + gap; x = anchor.X - size.Width / 2; }                          // 위
        else if (work.Left > mon.Left) { x = work.Left + gap; y = anchor.Y - size.Height / 2; }                      // 왼쪽
        else { x = work.Right - size.Width - gap; y = work.Bottom - size.Height - gap; }                              // 오른쪽·숨김
        x = Math.Clamp(x, work.Left + gap, work.Right - size.Width - gap);
        y = Math.Clamp(y, work.Top + gap, work.Bottom - size.Height - gap);
        m.AppWindow.MoveAndResize(new RectInt32(x, y, size.Width, size.Height));
        m.AppWindow.Show();
        m.Window.Activate();
        SetForegroundWindow(m.Hwnd);
        m.Emit("shown");
    }

    // MARK: 창들
    public void Close(string page)
    {
        // 읽기 창은 여러 개라 "reader:<key>" 로 어느 창인지 알려 준다
        if (page.StartsWith("reader:", StringComparison.Ordinal))
        {
            var key = page["reader:".Length..];
            readers.FirstOrDefault(r => r.Key == key)?.Window.Window.Close();
            return;
        }
        switch (page)
        {
            case "menu": HideMenu(); break;
            case "settings": settings?.Window.Close(); break;
            case "magazine": magazine?.Window.Close(); break;
            case "onboarding": onboarding?.Window.Close(); break;
            case "reader":
                var fg = GetForegroundWindow();
                readers.FirstOrDefault(r => r.Window.Hwnd == fg)?.Window.Window.Close();
                break;
        }
    }

    public void OpenSettings(string? tab)
    {
        if (settings is not null) { settings.Window.Activate(); if (tab is not null) settings.Emit("tab", tab); return; }
        settings = new WebWindow(Bridge, "settings", tab is null ? "" : "#" + Uri.EscapeDataString(tab), "Dropcap 설정", new SizeInt32(600, 640));
        if (settings.AppWindow.Presenter is OverlappedPresenter p) { p.IsResizable = false; p.IsMaximizable = false; }
        Center(settings);
        settings.Closed += () => settings = null;
        settings.Present();
    }

    // 관심 분야 고르기(G-03): 첫 실행에 자동으로, 설정 › 분야에서 다시 열기
    public void OpenOnboarding()
    {
        if (onboarding is not null) { onboarding.Window.Activate(); return; }
        onboarding = new WebWindow(Bridge, "onboarding", "", "관심 분야 고르기", new SizeInt32(680, 680));
        if (onboarding.AppWindow.Presenter is OverlappedPresenter p) { p.IsResizable = false; p.IsMaximizable = false; }
        Center(onboarding);
        onboarding.Closed += () => onboarding = null;
        onboarding.Present();
    }

    // M-01: 매거진은 여는 동안 작업 표시줄에 보인다(보통 창)
    public void OpenMagazine(string? page)
    {
        if (magazine is not null)
        {
            magazine.Window.Activate();
            if (page is not null) magazine.Emit("go", page);
            return;
        }
        magazine = new WebWindow(Bridge, "magazine", page is null ? "" : "page=" + Uri.EscapeDataString(page), "Dropcap", new SizeInt32(1180, 820));
        Center(magazine);
        magazine.Closed += () => magazine = null;
        magazine.Present();
    }

    // 읽기 창(R 절). 영상·팟캐스트는 원래 앱·브라우저로(R-17). from: 누른 카드의 화면 위치(R-14)
    public void OpenReader(NewsItem item, RectInt32? from)
    {
        if (item.ItemKind.OpensExternally()) { ExternalLink.Open(item.Link); return; }
        readerPage.Opening(item);
        var w = new WebWindow(Bridge, "reader", "key=" + Uri.EscapeDataString(item.Key), item.SourceName, new SizeInt32(760, 860));
        Center(w);
        // 여러 창은 24pt 씩 비켜서
        if (readers.LastOrDefault(r => r.Window.AppWindow.IsVisible)?.Window is { } last)
        {
            var k = w.Scale;
            var pos = last.AppWindow.Position;
            w.AppWindow.Move(new PointInt32(pos.X + (int)(24 * k), pos.Y + (int)(24 * k)));
        }
        var entry = new ReaderSlot(w, item.Key);
        readers.Add(entry);
        w.Closed += () =>
        {
            readers.Remove(entry);
            readerPage.Closed(entry.Key);   // 관찰을 끊고 말하기를 멈춤
        };
        w.Present(); // 모든 창이 같은 방식으로 열린다(docs/DESIGN.md · 카드 자리 from 은 쓰지 않음)
    }

    // 읽기 창 J·K(H-05): 그 창에서 같은 목록의 다음·이전 기사로. 이미 열린 기사면 그 창을 앞으로
    public void ReplaceReader(string fromKey, NewsItem next)
    {
        if (readers.FirstOrDefault(r => r.Key == next.Key) is { } open) { open.Window.Window.Activate(); return; }
        if (readers.FirstOrDefault(r => r.Key == fromKey) is not { } slot) { OpenReader(next, null); return; }
        readerPage.Closed(fromKey);
        readerPage.Opening(next);
        slot.Key = next.Key;
        slot.Window.Window.Title = next.SourceName;
        slot.Window.Go("key=" + Uri.EscapeDataString(next.Key));
    }

    private static void Center(WebWindow w)
    {
        GetCursorPos(out var p);
        var (work, _, _) = MonitorAt(p);
        var s = w.AppWindow.Size;
        w.AppWindow.Move(new PointInt32(work.Left + (work.Width - s.Width) / 2, work.Top + Math.Max(0, (work.Height - s.Height) / 2)));
    }

    // MARK: IAppUi
    public void ShowToasts(IReadOnlyList<NewsItem> items, bool sound)
    {
        // 방해하지 않기(N-23): 전체 화면 앱·발표 중·집중 지원이면 띄우지 않고 안 읽은 소식으로만 쌓는다
        if (UserBusy() && items.All(i => i.Id != AppModel.PreviewId)) return;
        toasts.ShowNews(items, sound);
    }

    public void ShowInfo(string title, string sub) => toasts.ShowInfo(title, sub);
    public void ShowDigest(int count) { if (!UserBusy()) toasts.ShowDigest(count, Model.State.Settings.Sound); }
    public void ShowWelcome() => toasts.ShowWelcome();
    public void PostSystem(IReadOnlyList<NewsItem> items, bool sound) { if (!UserBusy()) system.Post(items, sound); }
    public void ShowBundle(string section, IReadOnlyList<NewsItem> items, bool sound) { if (!UserBusy()) toasts.ShowBundle(section, items, sound); }
    public void PostBundle(string section, IReadOnlyList<NewsItem> items, bool sound) { if (!UserBusy()) system.PostBundle(section, items, sound); }
    public void OpenReader(NewsItem item) => OpenReader(item, pendingFrom);
    public void ShowWatch(string word, IReadOnlyList<NewsItem> items, bool sound) { if (!UserBusy()) toasts.ShowWatch(word, items, sound); }
    public void PostWatch(string word, IReadOnlyList<NewsItem> items, bool sound) { if (!UserBusy()) system.PostWatch(word, items, sound); }

    public void Quit()
    {
        Model.Stop();
        UnregisterHotKey(messages.Handle, HotKeyLatest);
        UnregisterHotKey(messages.Handle, HotKeyMagazine);
        system.Unregister();
        tray.Dispose();
        toasts.Dispose();
        foreach (var w in AllWindows().ToList()) w.Window.Close();
        messages.Dispose();
        Microsoft.UI.Xaml.Application.Current.Exit();
    }

    // MARK: 시험용(Q-03)
    public void RunTestHooks()
    {
        var env = Environment.GetEnvironmentVariables();
        string? E(string k) => env[k] as string;
        if (E("DROPCAP_TEST_TOAST") is not null) Later(1000, Model.Preview);
        if (E("DROPCAP_TEST_BURST") is not null)
            Later(1500, () => toasts.ShowNews([
                AppModel.PreviewItem(DateTimeOffset.Now),
                AppModel.PreviewItem(DateTimeOffset.Now) with { Id = "preview", SourceId = "anthropic", SourceName = "Anthropic", TitleKo = "두 번째 소식은 맺히지 않고 바로 떨어집니다" },
                AppModel.PreviewItem(DateTimeOffset.Now) with { Id = "preview", SourceId = "deepmind", SourceName = "Google DeepMind", TitleKo = "세 번째 소식", Important = true },
            ], Model.State.Settings.Sound));
        if (E("DROPCAP_TEST_URL") is { } u)
            Later(500, () => OpenReader(new NewsItem { Id = u, Title = u, Link = u, Date = DateTimeOffset.Now, SourceId = "openai", SourceName = "시험", Tier = "lab" }, null));
        if (E("DROPCAP_TEST_MAGAZINE") is not null) Later(1000, () => OpenMagazine(E("DROPCAP_TEST_MAGAZINE") is { Length: > 1 } pg ? pg : null));
        if (E("DROPCAP_TEST_SETTINGS") is not null) Later(1000, () => OpenSettings(null));
        if (E("DROPCAP_TEST_MENU") is not null) Later(1500, ToggleMenu);
        // 일반 뉴스 전환 시험 훅(맥과 같은 이름)
        if (E("DROPCAP_TEST_SECTIONS") is { } secs) Model.ChooseSections(secs.Split(',', StringSplitOptions.RemoveEmptyEntries));   // 고르기 없이 고른 것으로
        if (E("DROPCAP_TEST_ONBOARD") is not null) Later(800, OpenOnboarding);
        if (E("DROPCAP_TEST_BUNDLE") is { } bsec)
            Later(1500, () => toasts.ShowBundle(bsec, Model.State.Recent.Take(7).DefaultIfEmpty(AppModel.PreviewItem(DateTimeOffset.Now)).ToList(), Model.State.Settings.Sound));
        if (E("DROPCAP_TEST_MAG_SECTION") is { } msec) Later(1000, () => OpenMagazine("section:" + msec));
        if (E("DROPCAP_TEST_SUBSCRIBE") is { } subs)
            _ = Task.Run(async () =>
            {
                foreach (var id in subs.Split(','))
                    if (ChannelCatalog.All.FirstOrDefault(s => s.Id == id) is { } s) await Model.SubscribeAsync(s);
            });
    }

    private void Later(int ms, Action a)
    {
        var t = ui.CreateTimer();
        t.Interval = TimeSpan.FromMilliseconds(ms);
        t.IsRepeating = false;
        t.Tick += (_, _) => a();
        t.Start();
    }
}
