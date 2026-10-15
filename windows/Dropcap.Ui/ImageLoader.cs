using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using Dropcap.Core;
using SkiaSharp;

namespace Dropcap.Ui;

// 피드에서 온 사진 주소는 믿지 않으므로 사진은 모두 이것으로만 받는다(S-07·R-18·M-21):
// 공개 주소만(SafeHttp 의 안전 검사), 8MB 까지, 최대 1400px 로 줄여 JPEG 로 디스크에 담고, 600개 넘으면 500개로.
// 웹 화면은 https://img.dropcap.example/?u=<주소> 로 부르고 앱이 이 로더의 결과를 돌려준다.
public sealed class ImageLoader
{
    public static readonly ImageLoader Shared = new(Path.Combine(Store.Dir, "images"));

    public const int MaxBytes = (int)FetchLimit.Image;   // 사진 8MB(S-12)
    public const int MaxPixels = 1400;
    public const long MaxSourcePixels = 40_000_000;   // 풀기 전 가로×세로 상한(보안 점검: 6MB PNG 가 6GB 로 풀리는 압축 폭탄)

    // 머리만 읽어 크기를 본다. 너무 크거나 비어 있으면 false
    public static bool SafeDimensions(SKImageInfo info) => info.Width > 0 && info.Height > 0 && (long)info.Width * info.Height <= MaxSourcePixels;
    public const int DiskLimit = 600, DiskKeep = 500;

    private readonly string dir;
    private readonly ConcurrentDictionary<string, Task<byte[]?>> inflight = new();
    private readonly LinkedList<string> lru = new();
    private readonly Dictionary<string, (SKImage Image, LinkedListNode<string> Node)> memory = new();
    private int writes;

    public ImageLoader(string dir)
    {
        this.dir = dir;
        Directory.CreateDirectory(dir);
    }

    public string FileFor(string url) =>
        Path.Combine(dir, Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(url)))[..24] + ".jpg");

    // 줄인 JPEG 바이트(웹 화면용)
    public Task<byte[]?> JpegAsync(string url)
    {
        if (!UrlSafety.IsPublicHttp(url)) return Task.FromResult<byte[]?>(null);
        return inflight.GetOrAdd(url, u => Task.Run(async () =>
        {
            try { return await LoadAsync(u); }
            finally { inflight.TryRemove(u, out _); }
        }));
    }

    // 그리기용(알림 카드). 메모리에 160개까지.
    public async Task<SKImage?> ImageAsync(string url)
    {
        lock (memory) if (memory.TryGetValue(url, out var m)) { lru.Remove(m.Node); lru.AddFirst(m.Node); return m.Image; }
        var bytes = await JpegAsync(url);
        if (bytes is null) return null;
        var img = SKImage.FromEncodedData(bytes);
        if (img is null) return null;
        lock (memory)
        {
            if (!memory.ContainsKey(url)) memory[url] = (img, lru.AddFirst(url));
            while (memory.Count > 160 && lru.Last is { } last) { memory[last.Value].Image.Dispose(); memory.Remove(last.Value); lru.RemoveLast(); }
        }
        return img;
    }

    // 받은 사진의 가로 크기(줄인 뒤 — 맥도 1400px 로 줄인 사진의 크기를 본다). 못 받으면 null(R-22 표지 고르기)
    public async Task<int?> WidthAsync(string url)
    {
        var bytes = await JpegAsync(url);
        if (bytes is null) return null;
        using var codec = SKCodec.Create(new MemoryStream(bytes));
        return codec is null ? null : codec.Info.Width;
    }

    public SKImage? Cached(string url) { lock (memory) return memory.TryGetValue(url, out var m) ? m.Image : null; }

    private async Task<byte[]?> LoadAsync(string url)
    {
        var f = FileFor(url);
        try { if (File.Exists(f)) { File.SetLastWriteTimeUtc(f, DateTime.UtcNow); return await File.ReadAllBytesAsync(f); } } catch { }
        byte[] data;
        try
        {
            var r = await SafeHttp.GetAsync(url, req => req.Headers.Accept.ParseAdd("image/avif,image/webp,image/png,image/jpeg,image/*;q=0.8"),
                timeout: TimeSpan.FromSeconds(20), maxBody: MaxBytes);
            if (r.Status is < 200 or >= 300) return null;
            data = r.Body;
        }
        catch { return null; }
        var jpg = Shrink(data);
        if (jpg is null) return null;
        try { var tmp = f + ".tmp"; File.WriteAllBytes(tmp, jpg); File.Move(tmp, f, overwrite: true); } catch { }
        if (Interlocked.Increment(ref writes) % 20 == 0) Prune();
        return jpg;
    }

    // 최대 1400px 로 줄여 JPEG(품질 82). 그림이 아니면 null.
    public static byte[]? Shrink(byte[] data)
    {
        using var codec = SKCodec.Create(new MemoryStream(data));
        if (codec is null || !SafeDimensions(codec.Info)) return null;
        var info = codec.Info;
        var scale = Math.Min(1f, (float)MaxPixels / Math.Max(info.Width, info.Height));
        using var full = SKBitmap.Decode(codec);
        if (full is null) return null;
        using var oriented = Orient(full, codec.EncodedOrigin);
        var target = scale < 1
            ? oriented.Resize(new SKImageInfo(Math.Max(1, (int)(oriented.Width * scale)), Math.Max(1, (int)(oriented.Height * scale))), new SKSamplingOptions(SKFilterMode.Linear, SKMipmapMode.Linear))
            : oriented.Copy();
        using (target)
        {
            using var img = SKImage.FromBitmap(target);
            using var enc = img.Encode(SKEncodedImageFormat.Jpeg, 82);
            return enc?.ToArray();
        }
    }

    private static SKBitmap Orient(SKBitmap b, SKEncodedOrigin origin)
    {
        if (origin is SKEncodedOrigin.TopLeft or SKEncodedOrigin.Default) return b.Copy();
        var swap = origin is SKEncodedOrigin.LeftTop or SKEncodedOrigin.RightTop or SKEncodedOrigin.RightBottom or SKEncodedOrigin.LeftBottom;
        var o = new SKBitmap(swap ? b.Height : b.Width, swap ? b.Width : b.Height);
        using var c = new SKCanvas(o);
        switch (origin)
        {
            case SKEncodedOrigin.BottomRight: c.RotateDegrees(180, b.Width / 2f, b.Height / 2f); break;
            case SKEncodedOrigin.RightTop: c.Translate(o.Width, 0); c.RotateDegrees(90); break;
            case SKEncodedOrigin.LeftBottom: c.Translate(0, o.Height); c.RotateDegrees(270); break;
        }
        c.DrawBitmap(b, 0, 0);
        return o;
    }

    // 디스크 600개 넘으면 오래된 것부터 500개로
    internal void Prune()
    {
        try
        {
            var files = new DirectoryInfo(dir).GetFiles("*.jpg");
            if (files.Length <= DiskLimit) return;
            foreach (var f in files.OrderBy(f => f.LastWriteTimeUtc).Take(files.Length - DiskKeep)) f.Delete();
        }
        catch { }
    }
}
