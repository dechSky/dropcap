using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.Media.SpeechSynthesis;

namespace Dropcap.App;

// 소리 내어 읽기(R-09): 보이는 언어(번역이면 한국어)의 목소리로. 창을 닫으면 멈춘다.
internal sealed class Speaker
{
    public static readonly Speaker Shared = new();
    private readonly SpeechSynthesizer synth = new();
    private readonly MediaPlayer player = new();
    public bool Speaking { get; private set; }
    public event Action? Changed;

    private Speaker()
    {
        player.MediaEnded += (_, _) => { Speaking = false; Changed?.Invoke(); };
    }

    public async void Speak(string text, string language)
    {
        Stop();
        try
        {
            var voice = SpeechSynthesizer.AllVoices.FirstOrDefault(v => v.Language.StartsWith(language, StringComparison.OrdinalIgnoreCase))
                ?? SpeechSynthesizer.DefaultVoice;
            synth.Voice = voice;
            var stream = await synth.SynthesizeTextToStreamAsync(text);
            player.Source = MediaSource.CreateFromStream(stream, stream.ContentType);
            player.Play();
            Speaking = true;
        }
        catch { Speaking = false; }
        Changed?.Invoke();
    }

    public void Stop()
    {
        if (!Speaking) return;
        player.Pause();
        player.Source = null;
        Speaking = false;
        Changed?.Invoke();
    }
}
