// 앱 아이콘(③ 매거진 표지)을 shared/icon.json 으로 그려 iconset 이나 PNG 한 장으로 저장한다.
// 그리는 코드는 Sources/Dropcap/Core/IconArt.swift 와 같은 것을 쓰므로 둘을 이어 붙여 실행한다:
//   cat Sources/Dropcap/Core/IconArt.swift scripts/make-icon.swift > /tmp/mi.swift
//   swift /tmp/mi.swift ../shared/icon.json build/AppIcon.iconset     ← 16~512@2x 전부(32px 이하는 단순화 판)
//   swift /tmp/mi.swift ../shared/icon.json out.png 1024               ← 한 장
import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let doc = IconArt.load(URL(fileURLWithPath: args[1])) else {
    FileHandle.standardError.write("사용: make-icon <icon.json> <출력.iconset|출력.png> [크기]\n".data(using: .utf8)!)
    exit(1)
}

func save(_ size: Int, _ path: String) {
    guard let img = IconArt.appIcon(doc, size: size) else { fatalError("그리기 실패: \(size)") }
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let out = args[2]
if out.hasSuffix(".iconset") {
    try! FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    for s in [16, 32, 128, 256, 512] {
        save(s, "\(out)/icon_\(s)x\(s).png")
        save(s * 2, "\(out)/icon_\(s)x\(s)@2x.png")
    }
} else {
    save(args.count > 3 ? Int(args[3]) ?? 1024 : 1024, out)
}
