import AppKit

// "똑" 하는 물방울 소리를 파일 없이 즉석에서 만든다: 높은음에서 빠르게 떨어지는 짧은 사인파 두 개
enum DropSound {
    private static let sound: NSSound? = {
        let rate = 44100.0
        let length = Int(rate * 0.2)
        var samples = [Int16](repeating: 0, count: length)
        func tone(from f0: Double, to f1: Double, at start: Double, dur: Double, vol: Double) {
            var phase = 0.0
            let s0 = Int(start * rate), n = Int(dur * rate)
            for i in 0..<n where s0 + i < length {
                let t = Double(i) / Double(n)
                let f = f0 * pow(f1 / f0, t)            // 지수로 내려가는 음높이
                phase += 2 * .pi * f / rate
                let attack = min(1, Double(i) / (0.006 * rate))
                let env = attack * pow(1 - t, 2.2)       // 빠르게 사라짐
                let v = Double(samples[s0 + i]) + sin(phase) * env * vol * 32767
                samples[s0 + i] = Int16(max(-32767, min(32767, v)))
            }
        }
        tone(from: 1500, to: 620, at: 0, dur: 0.11, vol: 0.32)
        tone(from: 2100, to: 1300, at: 0.07, dur: 0.08, vol: 0.10)
        return NSSound(data: wav(samples, rate: Int(rate)))
    }()

    static func play() {
        guard let s = sound else { return }
        s.stop()
        s.volume = 0.6
        s.play()
    }

    private static func wav(_ samples: [Int16], rate: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        samples.forEach { u16(UInt16(bitPattern: $0)) }
        return d
    }
}
