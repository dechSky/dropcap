namespace Dropcap.Ui;

// "똑" 하는 물방울 소리를 파일 없이 즉석에서 만든다(N-04): 높은음에서 빠르게 떨어지는 짧은 사인파 두 개.
// 맥 DropSound 와 같은 음(1500→620Hz 0.11초 + 2100→1300Hz 0.08초), 음량 0.6 을 미리 곱해 둔다.
public static class DropSound
{
    public const int Rate = 44100;
    private static readonly Lazy<byte[]> wav = new(Make);
    public static byte[] Wav => wav.Value;

    private static byte[] Make()
    {
        var length = (int)(Rate * 0.2);
        var samples = new double[length];
        void Tone(double f0, double f1, double start, double dur, double vol)
        {
            var phase = 0.0;
            var s0 = (int)(start * Rate);
            var n = (int)(dur * Rate);
            for (var i = 0; i < n && s0 + i < length; i++)
            {
                var t = (double)i / n;
                var f = f0 * Math.Pow(f1 / f0, t);            // 지수로 내려가는 음높이
                phase += 2 * Math.PI * f / Rate;
                var attack = Math.Min(1, i / (0.006 * Rate));
                var env = attack * Math.Pow(1 - t, 2.2);       // 빠르게 사라짐
                samples[s0 + i] = Math.Clamp(samples[s0 + i] + Math.Sin(phase) * env * vol * 32767, -32767, 32767);
            }
        }
        Tone(1500, 620, 0, 0.11, 0.32);
        Tone(2100, 1300, 0.07, 0.08, 0.10);
        return ToWav(samples.Select(s => (short)(s * 0.6)).ToArray(), Rate);
    }

    public static byte[] ToWav(short[] samples, int rate)
    {
        using var ms = new MemoryStream();
        using var w = new BinaryWriter(ms);
        var bytes = samples.Length * 2;
        w.Write("RIFF"u8); w.Write(36 + bytes); w.Write("WAVE"u8);
        w.Write("fmt "u8); w.Write(16); w.Write((short)1); w.Write((short)1); w.Write(rate); w.Write(rate * 2); w.Write((short)2); w.Write((short)16);
        w.Write("data"u8); w.Write(bytes);
        foreach (var s in samples) w.Write(s);
        w.Flush();
        return ms.ToArray();
    }
}
