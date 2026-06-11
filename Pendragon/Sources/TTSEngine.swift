import Foundation
import AVFoundation
import Combine
import KokoroKit

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

    @Published var selectedModel: TTSModelVariant {
        didSet {
            guard oldValue != selectedModel else { return }
            UserDefaults.standard.set(selectedModel.rawValue, forKey: "tts.model")
            bridge.loadModel(variant: selectedModel)
        }
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

    // Serial synthesis queue — kokoro_synthesize is NOT thread-safe.
    // Only one synthesis Task runs at a time; the rest wait in the queue.
    private struct SynthItem { let id: UUID; let text: String; let autoPlay: Bool }
    private var synthQueue: [SynthItem] = []
    private var synthBusy = false   // true while a synthesizeToData task is running

    /// Requests queued while the model was still loading (before isReady).
    private var pendingUntilReady: [SynthItem] = []

    /// IDs tapped by the user while synthesis was in-flight — play as soon as the file is ready.
    private var pendingPlay: Set<UUID> = []

    /// Cache directory — WAV files named by message UUID. Wiped on quit.
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
        let voice    = UserDefaults.standard.string(forKey: "tts.selectedVoice") ?? KokoroBridge.defaultVoice
        let speed    = UserDefaults.standard.float(forKey: "tts.speechSpeed")
        let modelRaw = UserDefaults.standard.string(forKey: "tts.model") ?? ""
        selectedVoice  = voice
        speechSpeed    = speed > 0 ? speed : 1.0
        selectedModel  = TTSModelVariant(rawValue: modelRaw) ?? .fp32
        autoSpeak      = UserDefaults.standard.bool(forKey: "tts.autoSpeak")
        super.init()

        // Remove orphaned files from any previous crash
        wipeCacheDir()

        // Forward bridge objectWillChange so SwiftUI updates
        bridge.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bridgeCancellables)

        // When model finishes loading, enqueue everything that was waiting
        bridge.$isReady
            .filter { $0 }
            .sink { [weak self] _ in self?.drainPendingUntilReady() }
            .store(in: &bridgeCancellables)

        // Clear speaking ID when playback ends
        bridge.$isSpeaking
            .sink { [weak self] speaking in
                if !speaking { self?.speakingMessageId = nil }
            }
            .store(in: &bridgeCancellables)

        // Start loading immediately so the model is ready as early as possible
        bridge.loadModel(variant: selectedModel)
    }

    // MARK: - Lifecycle

    func start() { bridge.loadModel(variant: selectedModel) }

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

    /// Play a message. Uses the disk cache for instant playback if available.
    /// If synthesis is already queued, marks for playback when it finishes
    /// rather than double-queuing. If not queued at all, enqueues with autoPlay.
    func play(messageId: UUID, text: String) {
        speakingMessageId = messageId
        if playFromCache(messageId) { return }

        if synthesizingIds.contains(messageId) {
            // Already synthesising — just mark to play when the file is ready
            pendingPlay.insert(messageId)
            return
        }

        // Not in queue yet — enqueue with autoPlay so it plays as soon as done
        synthesizingIds.insert(messageId)
        let item = SynthItem(id: messageId, text: text, autoPlay: true)
        if bridge.isReady {
            enqueueForSynthesis(item)
        } else {
            if !pendingUntilReady.contains(where: { $0.id == messageId }) {
                pendingUntilReady.append(item)
            }
            if !bridge.isLoading { bridge.loadModel(variant: selectedModel) }
        }
    }

    func speak(text: String, voice: String? = nil, speed: Float? = nil) {
        bridge.speak(text: text, voice: voice ?? selectedVoice, speed: speed ?? speechSpeed)
    }

    func stopSpeaking() {
        bridge.stopSpeaking()
        speakingMessageId = nil
    }

    func pause()              { bridge.pause() }
    func resume()             { bridge.resume() }
    func skip(seconds: Double) { bridge.skip(seconds: seconds) }

    // MARK: - Export

    /// Export a cached WAV to MP3 (with WAV fallback) in ~/Downloads.
    /// Returns the saved URL so the caller can reveal it in Finder.
    func exportAudio(messageId: UUID, suggestedName: String) async -> URL? {
        let wavURL = cacheURL(for: messageId)
        guard isCached(messageId) else { return nil }

        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!

        // Sanitise filename: strip path-unsafe chars, cap length
        let safe = suggestedName
            .replacingOccurrences(of: "[/:\\\\*?\"<>|\\r\\n]", with: " ", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let stem = safe.isEmpty ? "Pendragon Audio" : String(safe.prefix(60))

        let wavOut = downloads.appendingPathComponent("\(stem).wav")
        return await KokoroBridge.exportAudio(from: wavURL, to: wavOut)
    }

    var availableVoices: [String] { bridge.availableVoices }

    // MARK: - Pre-synthesis cache (disk-backed, serial)

    /// Schedule background synthesis for a message.
    /// Shows "Preparing…" immediately. Serialises through the synthesis queue
    /// so concurrent generations don't race on the (non-thread-safe) C library.
    func synthesizeBackground(messageId: UUID, text: String, autoPlay: Bool = false) {
        // Already cached on disk
        if isCached(messageId) { cachedIds.insert(messageId); return }
        // Already in flight or queued
        guard !synthesizingIds.contains(messageId) else { return }

        // Mark as preparing right away so the UI updates immediately
        synthesizingIds.insert(messageId)

        let item = SynthItem(id: messageId, text: text, autoPlay: autoPlay)

        if bridge.isReady {
            enqueueForSynthesis(item)
        } else {
            // Wait for the model; it's already marked in synthesizingIds
            pendingUntilReady.append(item)
            if !bridge.isLoading { bridge.loadModel(variant: selectedModel) }
        }
    }

    /// Play pre-synthesised audio from disk. Returns false if no file exists.
    @discardableResult
    func playFromCache(_ messageId: UUID) -> Bool {
        let url = cacheURL(for: messageId)
        guard let data = try? Data(contentsOf: url) else { return false }
        bridge.playWAVData(data)
        return true
    }

    func hasCachedAudio(for messageId: UUID) -> Bool { isCached(messageId) }

    // MARK: - Serial synthesis queue

    /// Add an item to the serial queue and kick off processing if idle.
    private func enqueueForSynthesis(_ item: SynthItem) {
        synthQueue.append(item)
        processNextIfIdle()
    }

    /// Pull the next item from the queue and synthesise it. No-op if busy.
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

            // Process the next queued item
            self.processNextIfIdle()
        }
    }

    /// Called when the model finishes loading — move everything from
    /// pendingUntilReady into the serial synthesis queue.
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
