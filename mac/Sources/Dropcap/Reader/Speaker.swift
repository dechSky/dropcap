import AVFoundation

// 소리 내어 읽기: 보이는 언어(번역/원문)에 맞는 목소리로 제목과 본문을 읽는다
@MainActor
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var speaking = false
    private let synth = AVSpeechSynthesizer()

    override init() {
        super.init()
        synth.delegate = self
    }

    func toggle(title: String, paragraphs: [String], korean: Bool) {
        if speaking { stop(); return }
        let voice = AVSpeechSynthesisVoice(language: korean ? "ko-KR" : "en-US")
        for text in [title] + paragraphs where !text.isEmpty {
            let u = AVSpeechUtterance(string: text)
            u.voice = voice
            u.rate = AVSpeechUtteranceDefaultSpeechRate * (korean ? 1.05 : 1.0)
            u.postUtteranceDelay = 0.25
            synth.speak(u)
        }
        speaking = true
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        speaking = false
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in if !self.synth.isSpeaking { self.speaking = false } }
    }
}
