import Foundation
import AVFoundation
import Combine

// MARK: - TTSEngine

@MainActor
class TTSEngine: NSObject, ObservableObject {

    // MARK: - Published state

    @Published var autoSpeak = false {
        didSet {
            if !autoSpeak { bridge.stopSpeaking() }
            UserDefaults.standard.set(autoSpeak, forKey: "tts.autoSpeak")
        }
    }

    @Published var selectedVoice: String {
        didSet { UserDefaults.standard.set(selectedVoice, forKey: "tts.selectedVoice") }
    }

    @Published var speechSpeed: Float {
        didSet { UserDefaults.standard.set(speechSpeed, forKey: "tts.speechSpeed") }
    }

    /// Message IDs currently queued or being synthesised.
    @Published var synthesizingIds: Set<UUID> = []

    /// Message IDs whose audio file is ready on disk.
    @Published var cachedIds: Set<UUID> = []

    /// The message ID whose audio is currently playing (nil = silent).
    @Published var speakingMessageId: UUID? = nil

    var isReady: Bool    { bridge.isReady }
    var isStarting: Bool { bridge.isLoading }
    var isSpeaking: Bool { bridge.isSpeaking }
    var isPaused: Bool   { bridge.isPaused }
    var startError: String? { bridge.loadError }

    // MARK: - Private

    private let bridge = KokoroBridge()
    private var bridgeCancellables = Set<AnyCancellable>()

    private struct SynthItem { let id: UUID; let text: String; let autoPlay: Bool }
    private var synthQueue: [SynthItem] = []
    private var synthBusy = false

    private var pendingUntilReady: [SynthItem] = []
    private var pendingPlay: Set<UUID> = []

    private let cacheDir: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Pendragon/AudioCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private func cacheURL(for id: UUID) -> URL {
        cacheDir.appendingPathComponent("\(id.uuidString).wav")
    }
    private func isCached(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: cacheURL(for: id).path)
    }

    // MARK: - Init

    override init() {
        let savedVoice  = UserDefaults.standard.string(forKey: "tts.selectedVoice") ?? KokoroBridge.defaultVoice
        let speed       = UserDefaults.standard.float(forKey: "tts.speechSpeed")
        // Migrate from Qwen3 voice IDs — reset to default if saved voice isn't a Kokoro ID
        let voice = kokoroVoices.contains(where: { $0.id == savedVoice })
            ? savedVoice
            : KokoroBridge.defaultVoice
        selectedVoice = voice
        speechSpeed   = speed > 0 ? speed : 1.0
        autoSpeak     = UserDefaults.standard.bool(forKey: "tts.autoSpeak")
        super.init()

        wipeCacheDir()

        bridge.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bridgeCancellables)

        bridge.$isReady
            .filter { $0 }
            .sink { [weak self] _ in self?.drainPendingUntilReady() }
            .store(in: &bridgeCancellables)

        bridge.$isSpeaking
            .sink { [weak self] speaking in
                if !speaking { self?.speakingMessageId = nil }
            }
            .store(in: &bridgeCancellables)

        bridge.loadModel()
    }

    // MARK: - Lifecycle

    func start() { bridge.loadModel() }

    func shutdown() {
        bridge.stopSpeaking()
        speakingMessageId = nil
        synthesizingIds.removeAll()
        cachedIds.removeAll()
        synthQueue.removeAll()
        pendingUntilReady.removeAll()
        pendingPlay.removeAll()
        synthBusy = false
        wipeCacheDir()
    }

    // MARK: - Playback

    func play(messageId: UUID, text: String) {
        speakingMessageId = messageId
        if playFromCache(messageId) { return }

        if synthesizingIds.contains(messageId) {
            pendingPlay.insert(messageId)
            return
        }

        synthesizingIds.insert(messageId)
        let item = SynthItem(id: messageId, text: text, autoPlay: true)
        if bridge.isReady {
            enqueueForSynthesis(item)
        } else {
            if !pendingUntilReady.contains(where: { $0.id == messageId }) {
                pendingUntilReady.append(item)
            }
            if !bridge.isLoading { bridge.loadModel() }
        }
    }

    /// Synthesise arbitrary text and return raw WAV data. Used by WebpageAudioSheet.
    func synthesizeRaw(text: String) async -> Data? {
        await bridge.synthesizeToData(text: text, voice: selectedVoice, speed: speechSpeed)
    }

    func speak(text: String) {
        bridge.speak(text: text, voice: selectedVoice, speed: speechSpeed)
    }

    func playRaw(_ data: Data) { bridge.playWAVData(data) }

    func stopSpeaking() {
        bridge.stopSpeaking()
        speakingMessageId = nil
    }

    func pause()               { bridge.pause() }
    func resume()              { bridge.resume() }
    func skip(seconds: Double) { bridge.skip(seconds: seconds) }

    // MARK: - Export

    func exportAudio(messageId: UUID, suggestedName: String) async -> URL? {
        let wavURL = cacheURL(for: messageId)
        guard isCached(messageId) else { return nil }

        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!

        let safe = suggestedName
            .replacingOccurrences(of: "[/:\\\\*?\"<>|\\r\\n]", with: " ", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let stem = safe.isEmpty ? "Pendragon Audio" : String(safe.prefix(60))

        let wavOut = downloads.appendingPathComponent("\(stem).wav")
        return await KokoroBridge.exportAudio(from: wavURL, to: wavOut)
    }

    var availableVoices: [KokoroVoice] { bridge.availableVoices }

    // MARK: - Pre-synthesis cache

    func synthesizeBackground(messageId: UUID, text: String, autoPlay: Bool = false) {
        if isCached(messageId) { cachedIds.insert(messageId); return }
        guard !synthesizingIds.contains(messageId) else { return }

        synthesizingIds.insert(messageId)
        let item = SynthItem(id: messageId, text: text, autoPlay: autoPlay)

        if bridge.isReady {
            enqueueForSynthesis(item)
        } else {
            pendingUntilReady.append(item)
            if !bridge.isLoading { bridge.loadModel() }
        }
    }

    @discardableResult
    func playFromCache(_ messageId: UUID) -> Bool {
        let url = cacheURL(for: messageId)
        guard let data = try? Data(contentsOf: url) else { return false }
        bridge.playWAVData(data)
        return true
    }

    func hasCachedAudio(for messageId: UUID) -> Bool { isCached(messageId) }

    // MARK: - Serial synthesis queue

    private func enqueueForSynthesis(_ item: SynthItem) {
        synthQueue.append(item)
        processNextIfIdle()
    }

    private func processNextIfIdle() {
        guard !synthBusy, let item = synthQueue.first else { return }
        synthQueue.removeFirst()
        synthBusy = true

        let voice = selectedVoice
        let speed = speechSpeed
        let url   = cacheURL(for: item.id)

        Task { @MainActor in
            let data = await bridge.synthesizeToData(text: item.text, voice: voice, speed: speed)

            self.synthBusy = false
            self.synthesizingIds.remove(item.id)

            if let data {
                try? data.write(to: url, options: .atomic)
                self.cachedIds.insert(item.id)
                let shouldPlay = item.autoPlay || self.pendingPlay.contains(item.id)
                self.pendingPlay.remove(item.id)
                if shouldPlay {
                    self.speakingMessageId = item.id
                    self.bridge.playWAVData(data)
                }
            }

            self.processNextIfIdle()
        }
    }

    private func drainPendingUntilReady() {
        let items = pendingUntilReady
        pendingUntilReady.removeAll()
        for item in items { enqueueForSynthesis(item) }
    }

    private func wipeCacheDir() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: nil) else { return }
        for file in files { try? FileManager.default.removeItem(at: file) }
    }
}
