using Dropcap.Ui.Toast;
using SkiaSharp;

// 사용: IconGen <출력.ico>  ·  IconGen <출력.png> 1024
var output = args.Length > 0 ? args[0] : "app.ico";
Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(output))!);
if (output.EndsWith(".png", StringComparison.OrdinalIgnoreCase))
{
    var size = args.Length > 1 ? int.Parse(args[1]) : 1024;
    using var b = AppIcon.Render(size);
    using var img = SKImage.FromBitmap(b);
    using var data = img.Encode(SKEncodedImageFormat.Png, 100);
    File.WriteAllBytes(output, data.ToArray());
}
else File.WriteAllBytes(output, AppIcon.Ico(16, 24, 32, 48, 64, 128, 256));
Console.WriteLine(output);
