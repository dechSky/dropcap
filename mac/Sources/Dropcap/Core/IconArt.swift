// 앱 아이콘·상단바 상징을 shared/icon.json(세 판 공통 도형)으로 그린다.
// 앱(상단바)과 scripts/make-icon.swift(빌드 때 .icns)가 같이 쓴다 — 이 파일은 앱의 다른 코드에 기대지 않는다.
import AppKit

enum IconArt {
    struct Gradient: Decodable { let from: [Double]; let to: [Double]; let stops: [String] }
    struct Layer: Decodable {
        let d: String
        var fill: String?
        var opacity: Double?
        var gradient: Gradient?
        var evenodd: Bool?
        var rotate: [Double]? // [도, 중심 x, 중심 y] — SVG rotate() 와 같은 뜻
    }
    struct Shadow: Decodable { let dy: Double; let sigma: Double; let opacity: Double }
    struct Variant: Decodable { var tile: String?; var shadow: Shadow?; let layers: [Layer] }
    struct Symbol: Decodable { let size: Double; let read: [Layer]; let unread: [Layer] }
    struct Doc: Decodable { let app: Variant; let small: Variant; let smallMax: Int; let symbol: Symbol }

    static func load(_ url: URL) -> Doc? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Doc.self, from: data)
    }

    // 절대 좌표 M L H V C Z 만 읽는다(icon.json 의 약속)
    static func path(_ d: String) -> CGPath {
        let p = CGMutablePath()
        var nums: [Double] = [], cmd: Character = "M", cur = CGPoint.zero, i = d.startIndex
        func flush() {
            switch cmd {
            case "M", "L":
                var k = 0
                while k + 1 < nums.count {
                    cur = CGPoint(x: nums[k], y: nums[k + 1])
                    if cmd == "M" && k == 0 { p.move(to: cur) } else { p.addLine(to: cur) }
                    k += 2
                }
            case "H": for v in nums { cur.x = v; p.addLine(to: cur) }
            case "V": for v in nums { cur.y = v; p.addLine(to: cur) }
            case "C":
                var k = 0
                while k + 5 < nums.count {
                    cur = CGPoint(x: nums[k + 4], y: nums[k + 5])
                    p.addCurve(to: cur, control1: CGPoint(x: nums[k], y: nums[k + 1]), control2: CGPoint(x: nums[k + 2], y: nums[k + 3]))
                    k += 6
                }
            case "Z": p.closeSubpath()
            default: break
            }
            nums = []
        }
        while i < d.endIndex {
            let ch = d[i]
            if "MLHVCZ".contains(ch) {
                flush(); cmd = ch; i = d.index(after: i)
                if ch == "Z" { flush() }
            } else if ch == "-" || ch == "." || ch.isNumber {
                var j = d.index(after: i)
                while j < d.endIndex, d[j].isNumber || d[j] == "." { j = d.index(after: j) }
                nums.append(Double(d[i..<j]) ?? 0); i = j
            } else { i = d.index(after: i) }
        }
        flush()
        return p
    }

    static func color(_ hex: String, _ alpha: Double = 1) -> CGColor {
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return CGColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: alpha)
    }

    // ctx 는 왼쪽 아래가 원점인 보통 좌표. unit(1024 또는 16) 격자를 size 화소에 맞춰 y 를 뒤집어 그린다.
    // tint 가 있으면 모든 면을 그 색으로(상단바 템플릿).
    static func draw(_ layers: [Layer], tile: String? = nil, shadow: Shadow? = nil, in ctx: CGContext, size: CGFloat, unit: CGFloat, tint: CGColor? = nil) {
        let s = size / unit
        ctx.saveGState()
        ctx.translateBy(x: 0, y: size)
        ctx.scaleBy(x: s, y: -s)
        if let tile, let shadow {
            // 그림자 오프셋·흐림은 변환을 따르지 않으므로 화소 단위로(아래로 = 음수)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -shadow.dy * s), blur: shadow.sigma * 2 * s, color: CGColor(gray: 0, alpha: shadow.opacity))
            ctx.addPath(path(tile)); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        if let tile { ctx.addPath(path(tile)); ctx.clip() }
        for l in layers {
            ctx.saveGState()
            if let r = l.rotate, r.count == 3 {
                ctx.translateBy(x: r[1], y: r[2]); ctx.rotate(by: r[0] * .pi / 180); ctx.translateBy(x: -r[1], y: -r[2])
            }
            let rule: CGPathFillRule = l.evenodd == true ? .evenOdd : .winding
            ctx.addPath(path(l.d))
            if let g = l.gradient, tint == nil,
               let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: g.stops.map { color($0) } as CFArray, locations: nil) {
                ctx.clip(using: rule)
                ctx.drawLinearGradient(grad, start: CGPoint(x: g.from[0], y: g.from[1]), end: CGPoint(x: g.to[0], y: g.to[1]), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            } else {
                ctx.setFillColor(tint ?? color(l.fill ?? "#000000", l.opacity ?? 1))
                ctx.fillPath(using: rule)
            }
            ctx.restoreGState()
        }
        ctx.restoreGState()
        ctx.restoreGState()
    }

    // 앱 아이콘 한 장(size 화소): smallMax 이하면 단순화 판
    static func appIcon(_ doc: Doc, size: Int) -> CGImage? {
        let v = size <= doc.smallMax ? doc.small : doc.app
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        draw(v.layers, tile: v.tile, shadow: v.shadow, in: ctx, size: CGFloat(size), unit: 1024)
        return ctx.makeImage()
    }

    // 상단바 템플릿 상징(평소·새 소식). 크기는 포인트, 화면 배율에 맞춰 다시 그린다.
    static func symbol(_ doc: Doc, unread: Bool, points: CGFloat = 16) -> NSImage {
        let layers = unread ? doc.symbol.unread : doc.symbol.read
        let img = NSImage(size: NSSize(width: points, height: points), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(layers, in: ctx, size: rect.width, unit: doc.symbol.size, tint: CGColor(gray: 0, alpha: 1))
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = unread ? "Dropcap — 새 소식" : "Dropcap"
        return img
    }
}
