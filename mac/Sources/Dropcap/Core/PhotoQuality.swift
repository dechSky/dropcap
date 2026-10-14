import AppKit
import CoreGraphics
import Vision

// 분야 대표 사진 고르기(M-24): 웹사이트 화면 캡처·글자 위주 그림·로고가 표지·분야 카드에 뽑히지 않게
// 사진 비율·크기·글자 면적(Vision 글자 인식)·색 다양성·단색 바탕으로 점수를 매긴다. 기사 본문 사진·카드의 기사 사진에는 쓰지 않는다.
enum PhotoQuality {
    struct Score: Equatable, Sendable {
        var aspect: Double        // 0~1: 가로 사진(1.2~2.1)이 1
        var size: Double          // 0~1: 짧은 변 400px 이상이 1
        var textRatio: Double     // 0~1: 글자 영역이 차지하는 면적
        var colorVariety: Double  // 0~1: 몇 가지 색이 넓게 덮으면(화면 캡처·로고) 낮음
        var flatness: Double      // 0~1: 이웃과 색이 똑같은 칸의 몫(단색 바탕)
        var total: Double
    }

    // 이 점수보다 낮으면 대표 사진으로 쓰지 않는다
    static let threshold = 0.55

    static func aspectScore(width w: Double, height h: Double) -> Double {
        guard w > 0, h > 0 else { return 0 }
        let r = w / h
        if r >= 1.2 && r <= 2.1 { return 1 }
        if r < 1.2 { return max(0, (r - 0.6) / 0.6) }   // 세로·정사각에 가까울수록(로고·인물 사진) 낮게
        return max(0, 1 - (r - 2.1) / 1.5)               // 띠처럼 긴 배너
    }

    static func sizeScore(width w: Double, height h: Double) -> Double {
        let short = min(w, h)
        return max(0, min(1, (short - 150) / 250))
    }

    // 글자 면적 → 점수: 사진 귀퉁이의 작은 글자(2~3%)는 거의 깎지 않고, 15% 넘으면 0
    static func textScore(_ ratio: Double) -> Double { max(0, min(1, 1 - (ratio - 0.03) / 0.12)) }

    static func combine(aspect: Double, size: Double, textRatio: Double, colorVariety: Double, flatness: Double = 0) -> Score {
        var total = 0.15 * aspect + 0.15 * size + 0.4 * textScore(textRatio) + 0.3 * colorVariety
        // 아래에 걸리면 다른 점수가 좋아도 기준을 넘지 못하게 반으로: 글자가 5분의 1 넘게 덮음(글자 그림) ·
        // 단색 바탕이 넓음(그래픽·여백을 붙인 그림) · 단색 바탕에 글자가 있음(웹사이트·앱 화면 캡처). 밤하늘 같은 어두운 사진은 0.2 안팎이라 걸리지 않는다
        if textRatio >= 0.2 || flatness >= 0.35 || (flatness >= 0.25 && textRatio >= 0.05) { total *= 0.5 }
        return Score(aspect: aspect, size: size, textRatio: textRatio, colorVariety: colorVariety, flatness: flatness, total: total)
    }

    // 48×48 로 줄여 4비트씩 나눈 색 칸 중 가장 넓은 4칸이 차지하는 몫. 사진은 작고, 흰 바탕 화면 캡처·로고는 크다.
    static func colorVariety(_ cg: CGImage) -> Double {
        let n = 48
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0.5 }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        var bins: [Int: Int] = [:]
        for i in stride(from: 0, to: px.count, by: 4) {
            let k = Int(px[i] >> 4) << 8 | Int(px[i + 1] >> 4) << 4 | Int(px[i + 2] >> 4)
            bins[k, default: 0] += 1
        }
        let top4 = bins.values.sorted(by: >).prefix(4).reduce(0, +)
        let share = Double(top4) / Double(n * n)
        return max(0, min(1, (1 - share) * 1.3))
    }

    // 96×96 로 줄였을 때 오른쪽·아래 이웃과 색이 똑같은 칸의 몫. 화면 캡처·그래픽은 넓은 단색 바탕이 그대로 남고,
    // 사진은 흐린 배경이라도 잡음·결이 있어 거의 0 이다.
    static func flatness(_ cg: CGImage) -> Double {
        let n = 96
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        func same(_ a: Int, _ b: Int) -> Bool { px[a] == px[b] && px[a + 1] == px[b + 1] && px[a + 2] == px[b + 2] }
        var flat = 0
        for y in 0..<(n - 1) {
            for x in 0..<(n - 1) {
                let i = (y * n + x) * 4
                if same(i, i + 4) && same(i, i + n * 4) { flat += 1 }
            }
        }
        return Double(flat) / Double((n - 1) * (n - 1))
    }

    // 실제로 읽히는 글자(한·일·중·영)가 덮는 면적. 글자 '모양' 사각형만 찾는 방식은 흐린 얼굴·무늬를 글자로 잡아 쓰지 않는다.
    // 사진 귀퉁이의 통신사 표시 같은 작은 글자는 면적이 3% 안쪽이라 점수를 깎지 않는다(textScore).
    static func textRatio(_ cg: CGImage) -> Double {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = false
        req.recognitionLanguages = ["ko-KR", "ja-JP", "zh-Hans", "en-US"]
        do { try VNImageRequestHandler(cgImage: cg, options: [:]).perform([req]) } catch { return 0 }
        // 언어를 잘못 짚어 틀리게 읽어도(신뢰도 0.3) 글자가 있다는 뜻이므로 면적에 넣는다
        let area = (req.results ?? []).filter { $0.confidence >= 0.3 }.reduce(0.0) { $0 + Double($1.boundingBox.width * $1.boundingBox.height) }
        return min(1, area)
    }

    // 무거운 일(Vision)이므로 화면 줄기 밖에서 부른다
    static func score(_ cg: CGImage) -> Score {
        let w = Double(cg.width), h = Double(cg.height)
        return combine(aspect: aspectScore(width: w, height: h), size: sizeScore(width: w, height: h),
                       textRatio: textRatio(cg), colorVariety: colorVariety(cg), flatness: flatness(cg))
    }

    // 비동기에서는 이것만 쓴다: Vision 글자 읽기는 오래 막히는 동기 호출이라 Swift 동시성 공용 스레드에서 돌리면
    // 분야 12개가 한꺼번에 재는 첫 실행에 공용 스레드가 모두 막혀 앱 전체의 비동기 일(확인·알림·Task.sleep)이 멈췄다(E2E).
    // 전용 줄 하나에서 차례로 잰다.
    private static let queue = DispatchQueue(label: "dropcap.photo-quality", qos: .utility)
    static func scoreAsync(_ cg: CGImage) async -> Score {
        await withCheckedContinuation { c in queue.async { c.resume(returning: score(cg)) } }
    }

    static func good(_ score: Double?) -> Bool { (score ?? 1) >= threshold } // 아직 재지 않은 사진은 막지 않는다
}

// 분야 대표 사진: 점수를 잰 사진 중 기준을 넘는 것을 고른다(분야 카드·매거진 표지가 쓴다)
@MainActor
enum SectionPhoto {
    // 이미 잰 점수만으로 고르기(즉시). 잰 점수가 없으면 앞에서부터.
    static func best(_ items: [NewsItem], scores: [String: Double]) -> NewsItem? {
        let withPhoto = items.filter { $0.image != nil && !ImageKey.isJunk($0.image) }
        return withPhoto.first { PhotoQuality.good(scores[$0.image!]) && scores[$0.image!] != nil }
            ?? withPhoto.first { PhotoQuality.good(scores[$0.image!]) }
    }

    // 분야 하나의 대표 사진: 앞의 사진들을 재 가며(최대 limit 장) 기준을 넘는 첫 사진. 잰 점수는 DB 에 남긴다. 없으면 nil.
    static func pick(_ items: [NewsItem], limit: Int = 6) async -> (item: NewsItem, image: NSImage)? {
        let cands = items.filter { $0.image != nil && !ImageKey.isJunk($0.image) }.prefix(limit)
        let known = Database.shared.imageScores(cands.map { $0.image! })
        for it in cands {
            let url = it.image!
            if let s = known[url], !PhotoQuality.good(s) { continue }
            guard let img = await ImageLoader.shared.image(url), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let s: Double
            if let k = known[url] { s = k } else {
                let sc = await PhotoQuality.scoreAsync(cg)
                Database.shared.saveImageScore(url, sc)
                s = sc.total
            }
            if PhotoQuality.good(s) { return (it, img) }
        }
        return nil // 기준 밑 사진은 대신 쓰지 않는다(사진 없이 색면으로)
    }
}
