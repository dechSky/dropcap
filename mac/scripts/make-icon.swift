// 앱 아이콘(물방울)을 코드로 그려 1024px PNG 로 저장: swift scripts/make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// 바탕: 맥 아이콘 격자에 맞춘 둥근 사각형(824px) + 깊은 남색 그라데이션
let inset: CGFloat = 100
let tile = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(tilePath); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    NSColor(srgbRed: 0.10, green: 0.13, blue: 0.30, alpha: 1).cgColor,
    NSColor(srgbRed: 0.04, green: 0.05, blue: 0.13, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

// 물결 고리
for (r, a) in [(300.0, 0.10), (225.0, 0.16)] {
    ctx.setStrokeColor(NSColor(srgbRed: 0.45, green: 0.75, blue: 1, alpha: a).cgColor)
    ctx.setLineWidth(10)
    ctx.strokeEllipse(in: CGRect(x: 512 - r, y: 330 - r * 0.32, width: r * 2, height: r * 0.64))
}

// 물방울: 아래는 원, 위는 뾰족
let cx: CGFloat = 512, cy: CGFloat = 420, R: CGFloat = 175
let drop = CGMutablePath()
drop.move(to: CGPoint(x: cx, y: cy + R * 2.25))
drop.addCurve(to: CGPoint(x: cx + R, y: cy), control1: CGPoint(x: cx + R * 0.35, y: cy + R * 1.55), control2: CGPoint(x: cx + R, y: cy + R * 0.85))
drop.addArc(center: CGPoint(x: cx, y: cy), radius: R, startAngle: 0, endAngle: .pi, clockwise: true)
drop.addCurve(to: CGPoint(x: cx, y: cy + R * 2.25), control1: CGPoint(x: cx - R, y: cy + R * 0.85), control2: CGPoint(x: cx - R * 0.35, y: cy + R * 1.55))
drop.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 40, color: NSColor(srgbRed: 0.2, green: 0.6, blue: 1, alpha: 0.6).cgColor)
ctx.addPath(drop); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(drop); ctx.clip()
let water = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    NSColor(srgbRed: 0.55, green: 0.88, blue: 1, alpha: 1).cgColor,
    NSColor(srgbRed: 0.16, green: 0.52, blue: 1, alpha: 1).cgColor,
    NSColor(srgbRed: 0.18, green: 0.25, blue: 0.95, alpha: 1).cgColor] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(water, start: CGPoint(x: cx - 120, y: cy + R * 2.2), end: CGPoint(x: cx + 120, y: cy - R), options: [])
// 반사광
ctx.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
ctx.fillEllipse(in: CGRect(x: cx - 105, y: cy + 40, width: 48, height: 78))
ctx.setFillColor(NSColor.white.withAlphaComponent(0.5).cgColor)
ctx.fillEllipse(in: CGRect(x: cx - 92, y: cy - 18, width: 22, height: 22))
ctx.restoreGState()

// 위쪽 유리 반사
let gloss = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [NSColor.white.withAlphaComponent(0.10).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.midY), options: [])
ctx.restoreGState()
img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
