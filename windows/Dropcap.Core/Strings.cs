namespace Dropcap.Core;

// 앱 이름·주제가 들어간 문구는 여기 한곳에(추가 지시 2: 일반 '매거진'으로 넓힐 때 이 표만 고친다). 맥 문구와 같게.
public static class Strings
{
    public const string AppName = "Dropcap";
    public static string Magazine => "매거진";                                       // 'AI 매거진' → '매거진'
    public static string MoreNews(int n) => $"새 소식 {n}건 더";
    public const string MoreCard = "새 소식";                                         // 알림 "새 소식 N건 더 · 트레이 아이콘에서 확인"
    public const string Digest = "오늘의 브리핑";                                      // N-16
    public static string DigestSub(int n) => $"지난 하루 소식 {n}건 — 매거진에서 보기";
    public const string WelcomeTitle = "Dropcap 실행 중";
    public const string WelcomeSub = "새 소식이 오면 이렇게 화면 위에서 떨어집니다";
    public const string PreviewTitleKo = "새 소식은 이렇게 떨어집니다";
    public const string PreviewTitle = "This is how new stories will drop in";
    public const string TrayHint = "트레이 아이콘에서 확인";
    public static string Bundle(string section, int n) => $"{Sections.Name(section)} {n}건";             // 묶음 한 방울(G-07)
    public const string BundleSub = "누르면 매거진의 이 분야 지면";
}
