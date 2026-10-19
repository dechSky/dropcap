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
    public const long MemoryLimitBytes = 64L << 20;

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

    // 그리기용(알림 카드). 메모리에는 풀린 크기로 64MB·160장까지(최근 사용 순 — 오래 안 쓴 것부터 버림).
    // 예전엔 장 수(160)로만 묶어 큰 사진이면 수백 MB 를 붙들 수 있었다
    public async Task<SKImage?> ImageAsync(string url)
    {
        if (Cached(url) is { } hit) return hit;
        var bytes = await JpegAsync(url);
        if (bytes is null) return null;
        var img = SKImage.FromEncodedData(bytes);
        if (img is null) return null;
        lock (memory)
        {
            // 같은 주소를 동시에 불러 먼저 담긴 것이 있으면 그것을 쓰고 이 그림은 버린다
            if (memory.TryGetValue(url, out var won)) { img.Dispose(); Touch(won.Node); return won.Image; }
            var cost = Cost(img);
            if (cost > MemoryLimitBytes) return img;   // 상한보다 큰 한 장은 담지 않는다(부른 쪽이 쓰고 버림)
            memory[url] = (img, lru.AddFirst(url));
            memoryBytes += cost;
            while ((memoryBytes > MemoryLimitBytes || memory.Count > MemoryLimitCount) && lru.Last is { } last && last.Value != url)
            {
                var old = memory[last.Value];
                memoryBytes -= Cost(old.Image);
                old.Image.Dispose();
                memory.Remove(last.Value);
                lru.RemoveLast();
            }
        }
        return img;
    }

    public const int MemoryLimitCount = 160;
    private long memoryBytes;
    // 풀었을 때 크기(가로×세로×4)
    private static long Cost(SKImage img) => Math.Max(1L, (long)img.Width * img.Height * 4);
    private void Touch(LinkedListNode<string> node) { lru.Remove(node); lru.AddFirst(node); }

    // 받은 사진의 가로 크기(줄인 뒤 — 맥도 1400px 로 줄인 사진의 크기를 본다). 못 받으면 null(R-22 표지 고르기)
    public async Task<int?> WidthAsync(string url)
    {
        var bytes = await JpegAsync(url);
        if (bytes is null) return null;
        using var codec = SKCodec.Create(new MemoryStream(bytes));
        return codec is null ? null : codec.Info.Width;
    }

    // 시험용: 메모리에 담은 사진의 풀린 크기 합 · 마지막으로 Shrink 가 푼 크기
    internal long MemoryBytes { get { lock (memory) return memoryBytes; } }
    [ThreadStatic] internal static SKSizeI LastDecode;

    public SKImage? Cached(string url)
    {
        lock (memory)
        {
            if (!memory.TryGetValue(url, out var m)) return null;
            Touch(m.Node);   // 그릴 때 쓴 것도 '최근 사용'
            return m.Image;
        }
    }

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
        // 원본 전체를 풀지 않는다: JPEG 등은 풀 때 1/2·1/4·1/8 로 줄여 풀 수 있다(줄인 결과보다 작아지지 않는 크기로).
        // 그 뒤 정확한 크기로 다시 줄인다. 줄여 풀 수 없는 형식(PNG 등)은 예전처럼 다 푼다
        using var full = DecodeScaled(codec, scale);
        if (full is null) return null;
        LastDecode = new SKSizeI(full.Width, full.Height);
        using var oriented = Orient(full, codec.EncodedOrigin);
        // 목표 크기는 원본 기준(줄여 풀었어도 결과 크기는 예전과 같게)
        var (ow, oh) = oriented.Width == full.Width ? (info.Width, info.Height) : (info.Height, info.Width);
        var tw = Math.Max(1, (int)(ow * scale));
        var th = Math.Max(1, (int)(oh * scale));
        var target = oriented.Width != tw || oriented.Height != th
            ? oriented.Resize(new SKImageInfo(tw, th), new SKSamplingOptions(SKFilterMode.Linear, SKMipmapMode.Linear))
            : oriented.Copy();
        using (target)
        {
            using var img = SKImage.FromBitmap(target);
            using var enc = img.Encode(SKEncodedImageFormat.Jpeg, 82);
            return enc?.ToArray();
        }
    }

    private static SKBitmap? DecodeScaled(SKCodec codec, float scale)
    {
        var info = codec.Info;
        if (scale < 1)
        {
            var dims = codec.GetScaledDimensions(scale);
            var minW = Math.Max(1, (int)(info.Width * scale));
            var minH = Math.Max(1, (int)(info.Height * scale));
            if (dims.Width >= minW && dims.Height >= minH && (dims.Width < info.Width || dims.Height < info.Height))
            {
                var bmp = new SKBitmap(new SKImageInfo(dims.Width, dims.Height, SKImageInfo.PlatformColorType, info.AlphaType == SKAlphaType.Unpremul ? SKAlphaType.Premul : info.AlphaType));
                var r = codec.GetPixels(bmp.Info, bmp.GetPixels());
                if (r is SKCodecResult.Success or SKCodecResult.IncompleteInput) return bmp;
                bmp.Dispose();
            }
        }
        return SKBitmap.Decode(codec);
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
