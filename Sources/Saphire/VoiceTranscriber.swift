import AVFoundation
import Speech

/// Live microphone capture + on-device speech-to-text for push-to-talk
/// dictation. A single AVAudioEngine input tap feeds both the speech
/// recognizer and the 5-bar level meter shown in the overlay.
///
/// Marked `@unchecked Sendable` so the audio render-thread tap closure can
/// touch the recognition request directly (Apple's documented pattern). All
/// UI callbacks are marshalled back to the main actor.
final class VoiceTranscriber: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-ES"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// 5 normalized bar heights (0…1), delivered on the main actor.
    var onLevels: (@MainActor @Sendable ([CGFloat]) -> Void)?
    /// Latest full transcript, delivered on the main actor.
    var onTranscript: (@MainActor @Sendable (String) -> Void)?

    private(set) var isRunning = false

    /// Smoothed equalizer bars driven by the input level. Touched only from the
    /// (serial) audio render thread once capture starts.
    private var bars = [CGFloat](repeating: 0, count: 5)
    private let barWeights: [CGFloat] = [0.55, 0.85, 1.0, 0.8, 0.5]

    /// Requests microphone + speech-recognition authorization. Returns true
    /// only when both are granted.
    static func requestPermissions() async -> Bool {
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        guard mic else { return false }
        let speech = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                c.resume(returning: status == .authorized)
            }
        }
        return speech
    }

    func start() throws {
        guard !isRunning else { return }
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(domain: "Voice", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Reconocimiento de voz no disponible."])
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // Keep audio local when the device supports it; otherwise fall back to
        // Apple's server recognition so dictation still works.
        req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request = req
        bars = [CGFloat](repeating: 0, count: 5)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.request?.append(buffer)
            self.pushLevel(VoiceTranscriber.power(of: buffer))
        }

        engine.prepare()
        try engine.start()
        isRunning = true

        task = recognizer.recognitionTask(with: req) { [weak self] result, _ in
            guard let self, let result else { return }
            let text = result.bestTranscription.formattedString
            if let cb = self.onTranscript {
                Task { @MainActor in cb(text) }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        if let cb = onLevels {
            Task { @MainActor in cb(Array(repeating: 0, count: 5)) }
        }
    }

    /// Drives the 5 equalizer bars from the current input level. A per-bar
    /// weight + light jitter and smoothing make them move like a spectrum
    /// rather than a single level meter.
    private func pushLevel(_ level: CGFloat) {
        for i in 0..<bars.count {
            let jitter = CGFloat.random(in: 0.80...1.15)
            let target = min(1, level * barWeights[i] * jitter)
            bars[i] = bars[i] * 0.6 + target * 0.4
        }
        let snapshot = bars
        if let cb = onLevels {
            Task { @MainActor in cb(snapshot) }
        }
    }

    /// Average power of a buffer mapped to 0…1 (rough, for visualization only).
    private static func power(of buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let ch = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n {
            let s = ch[i]
            sum += s * s
        }
        let rms = sqrt(sum / Float(n))
        let db = 20 * log10(max(rms, 1e-7))     // ~ -140…0 dB
        let norm = (db + 50) / 50               // map -50…0 dB → 0…1
        return CGFloat(min(max(norm, 0), 1))
    }
}
