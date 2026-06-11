import Foundation
import AVFoundation
import KokoroKit

// MARK: - Model variants

/// The three Kokoro ONNX model sizes bundled with the app.
enum TTSModelVariant: String, CaseIterable, Codable {
    case fp32 = "fp32"   // 310 MB — full precision
    case fp16 = "fp16"   // 169 MB — half precision
    case int8 = "int8"   //  88 MB — integer quantised

    var resourceName: String {
        switch self {
        case .fp32: return "kokoro-v1.0"
        case .fp16: return "kokoro-v1.0.fp16"
        case .int8: return "kokoro-v1.0.int8"
        }
    }

    var displayName: String {
        switch self {
        case .fp32: return "Large"
        case .fp16: return "Medium"
        case .int8: return "Small"
        }
    }

    var precision: String {
        switch self {
        case .fp32: return "FP32"
        case .fp16: return "FP16"
        case .int8: return "INT8"
        }
    }

    var fileSize: String {
        switch self {
        case .fp32: return "310 MB"
        case .fp16: return "169 MB"
        case .int8: return "88 MB"
        }
    }

    /// 1–5 (higher = better audio quality)
    var qualityScore: Int {
        switch self { case .fp32: return 5; case .fp16: return 4; case .int8: return 3 }
    }

    /// 1–5 (higher = faster synthesis)
    var speedScore: Int {
        switch self { case .fp32: return 3; case .fp16: return 4; case .int8: return 5 }
    }

    var description: String {
        switch self {
        case .fp32:
            return "Full 32-bit float precision. Reference quality. " +
                   "Best for critical listening or final output."
        case .fp16:
            return "16-bit float. Near-identical quality on Apple Silicon " +
                   "(M-series has native FP16 units), ~45% smaller and faster to load."
        case .int8:
            return "8-bit integer quantisation. Fastest synthesis, smallest RAM footprint. " +
                   "Slight softening of tonal nuances — still excellent for everyday use."
        }
    }

    /// Short note shown under the speed/quality bars.
    var recommendation: String {
        switch self {
        case .fp32: return "Best quality · heaviest"
        case .fp16: return "Recommended for Apple Silicon"
        case .int8: return "Fastest · lightest"
        }
    }
}

// MARK: - KokoroBridge

/// Native Kokoro TTS bridge.
/// Wraps the C++ KokoroTTS implementation loaded via KokoroKit module.
@MainActor
final class KokoroBridge: NSObject, ObservableObject, AVAudioPlayerDelegate {

    // MARK: - Published state
    @Published var isReady = false
    @Published var isLoading = false
    @Published var isSpeaking = false
    @Published var isPaused = false
    @Published var loadError: String? = nil

    // MARK: - Private
    private var handle: KokoroHandle? = nil
    private var player: AVAudioPlayer? = nil

    static let defaultVoice = "af_heart"

    // MARK: - Lifecycle

    override init() {
        super.init()
    }

    deinit {
        if let h = handle {
            kokoro_destroy(h)
        }
    }

    // MARK: - Loading

    func loadModel(variant: TTSModelVariant = .fp32) {
        guard !isLoading else { return }
        // Tear down existing handle if switching models
        if let h = handle {
            stopSpeaking()
            kokoro_destroy(h)
            handle = nil
            isReady = false
        }
        isLoading = true
        loadError = nil

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            let bundle = Bundle.main
            guard let modelURL    = bundle.url(forResource: variant.resourceName, withExtension: "onnx"),
                  let voicesURL   = bundle.url(forResource: "voices", withExtension: "bin"),
                  let espeakData  = bundle.url(forResource: "espeak-ng-data", withExtension: nil)
            else {
                await self.setError("Model file not found: \(variant.resourceName).onnx")
                return
            }

            // libespeak-ng.dylib is embedded in Contents/Frameworks/
            let espeakLib = bundle.bundleURL
                .appendingPathComponent("Contents/Frameworks/libespeak-ng.dylib")

            let h = kokoro_create(
                modelURL.path,
                voicesURL.path,
                espeakLib.path,
                espeakData.path
            )

            await MainActor.run {
                if let h {
                    self.handle = h
                    self.isReady = true
                    self.isLoading = false
                } else {
                    let err = String(cString: kokoro_last_error())
                    self.loadError = err.isEmpty ? "Unknown error" : err
                    self.isLoading = false
                }
            }
        }
    }

    private func setError(_ message: String) async {
        await MainActor.run {
            self.loadError = message
            self.isLoading = false
        }
    }

    // MARK: - Speech

    func speak(text: String, voice: String = KokoroBridge.defaultVoice, speed: Float = 1.0) {
        guard isReady, let h = handle else { return }
        stopSpeaking()

        let cleanText = KokoroBridge.stripMarkdown(text)
        guard !cleanText.isEmpty else { return }

        let voiceCopy = voice
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var outSamples: Int32 = 0
            var outSampleRate: Int32 = 0

            // kokoro_synthesize is called off-MainActor; h captured as Optional<UnsafeMutableRawPointer>
            let audioData = kokoro_synthesize(h, cleanText, voiceCopy, speed, &outSamples, &outSampleRate)
            guard let audioData else {
                let err = String(cString: kokoro_last_error())
                print("[KokoroBridge] Synthesis error: \(err)")
                return
            }
            defer { kokoro_free_audio(audioData) }

            let count = Int(outSamples)
            let sr    = Int(outSampleRate)
            guard count > 0 else { return }

            // Convert float32 PCM → int16 WAV in memory (static nonisolated helper)
            let wavData = Self._makeWAV(samples: audioData, count: count, sampleRate: sr)
            guard let wavData else { return }

            await MainActor.run {
                self.playWAV(wavData)
            }
        }
    }

    func stopSpeaking() {
        player?.stop()
        player = nil
        isSpeaking = false
        isPaused = false
    }

    func pause() {
        guard isSpeaking, !isPaused else { return }
        player?.pause()
        isPaused = true
    }

    func resume() {
        guard isSpeaking, isPaused else { return }
        player?.play()
        isPaused = false
    }

    func skip(seconds: Double) {
        guard let p = player else { return }
        p.currentTime = max(0, min(p.duration, p.currentTime + seconds))
        // If paused, stay paused; if playing, keep playing
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isSpeaking = false
            self.isPaused = false
            self.player = nil
        }
    }

    // MARK: - Helpers

    /// Synthesize text to WAV Data without playing — for pre-caching.
    /// Runs the heavy ONNX call off the main thread; returns nil on failure.
    func synthesizeToData(text: String, voice: String, speed: Float) async -> Data? {
        guard isReady, let h = handle else { return nil }
        let cleanText = Self.stripMarkdown(text)
        guard !cleanText.isEmpty else { return nil }
        let v = voice; let s = speed
        return await withCheckedContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                var outSamples: Int32 = 0
                var outSampleRate: Int32 = 0
                let audioData = kokoro_synthesize(h, cleanText, v, s, &outSamples, &outSampleRate)
                guard let audioData else { continuation.resume(returning: nil); return }
                defer { kokoro_free_audio(audioData) }
                let wav = Self._makeWAV(samples: audioData, count: Int(outSamples), sampleRate: Int(outSampleRate))
                continuation.resume(returning: wav)
            }
        }
    }

    /// Play pre-synthesised WAV data immediately (called from TTSEngine cache).
    func playWAVData(_ data: Data) { playWAV(data) }

    func playWAV(_ data: Data) {
        do {
            let p = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue)
            p.delegate = self
            p.prepareToPlay()
            p.play()
            player = p
            isSpeaking = true
        } catch {
            print("[KokoroBridge] AVAudioPlayer error: \(error)")
        }
    }

    /// Build a WAV Data from float32 PCM samples (nonisolated so it can be called from Task.detached)
    private nonisolated static func _makeWAV(samples: UnsafePointer<Float>, count: Int, sampleRate: Int) -> Data? {
        var int16Buf = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let v = max(-1.0, min(1.0, samples[i]))
            int16Buf[i] = Int16(v * 32767.0)
        }
        let dataSize    = count * 2
        let chunkSize   = 36 + dataSize
        let byteRate    = sampleRate * 2
        let blockAlign  = 2
        let bitsPerSample = 16

        var wav = Data(capacity: 44 + dataSize)
        func appendU32(_ v: Int)    { var x = UInt32(v); wav.append(contentsOf: withUnsafeBytes(of: &x) { Array($0) }) }
        func appendU16(_ v: Int)    { var x = UInt16(v); wav.append(contentsOf: withUnsafeBytes(of: &x) { Array($0) }) }
        func appendTag(_ s: String) { wav.append(contentsOf: s.utf8) }

        appendTag("RIFF"); appendU32(chunkSize)
        appendTag("WAVE")
        appendTag("fmt "); appendU32(16)
        appendU16(1 /*PCM*/); appendU16(1 /*mono*/)
        appendU32(sampleRate); appendU32(byteRate)
        appendU16(blockAlign); appendU16(bitsPerSample)
        appendTag("data"); appendU32(dataSize)
        int16Buf.withUnsafeBytes { wav.append(contentsOf: $0) }
        return wav
    }

    /// Strip markdown formatting from text before TTS synthesis.
    static func stripMarkdown(_ text: String) -> String {
        var s = text
        // Code blocks
        s = s.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "`[^`]+`", with: " ", options: .regularExpression)
        // Headers
        s = s.replacingOccurrences(of: "(?m)^#{1,6}\\s*", with: "", options: .regularExpression)
        // Bold/italic
        s = s.replacingOccurrences(of: "\\*{1,3}([^*]+)\\*{1,3}", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "_{1,3}([^_]+)_{1,3}", with: "$1", options: .regularExpression)
        // Links
        s = s.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]+\\)", with: "$1", options: .regularExpression)
        // Horizontal rules
        s = s.replacingOccurrences(of: "(?m)^[-*_]{3,}$", with: "", options: .regularExpression)
        // Multiple spaces/newlines
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Audio export

    /// Copy the cached WAV to ~/Downloads (or another destination).
    /// Returns the final URL on success, nil on failure.
    nonisolated static func exportAudio(from wavURL: URL, to outputURL: URL) async -> URL? {
        return await Task.detached(priority: .userInitiated) {
            let dest = Self._uniqueURL(outputURL)
            do {
                try FileManager.default.copyItem(at: wavURL, to: dest)
                return dest
            } catch {
                return nil
            }
        }.value
    }

    /// Append a numeric suffix to avoid overwriting an existing file.
    private nonisolated static func _uniqueURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let dir  = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext  = url.pathExtension
        var i    = 2
        var candidate = url
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)"
            candidate = dir.appendingPathComponent(name)
            i += 1
        }
        return candidate
    }

    // MARK: - Available voices

    var availableVoices: [String] {
        guard let h = handle else { return [] }
        var count: Int32 = 0
        guard let voices = kokoro_get_voices(h, &count) else { return [] }
        defer { kokoro_free_voices(voices, count) }
        return (0..<Int(count)).compactMap { i -> String? in
            voices[i].map { String(cString: $0) }
        }
    }
}
