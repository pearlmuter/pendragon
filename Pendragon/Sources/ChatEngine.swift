import Foundation
import SwiftUI
import AppKit
import AVFoundation
import PDFKit
import Combine
import EventKit

// MARK: - Context size options

/// Available KV-cache context sizes.
/// Gemma 4 12B uses hybrid SWA: 40 sliding-window layers (bounded to 1024 tokens each)
/// + 8 global attention layers that scale linearly with context.
/// KV cache ≈ 335 MB fixed (SWA) + n_ctx × 16 KB (global layers).
enum ContextSizeOption: Int32, CaseIterable, Identifiable {
    case k8   =   8_192
    case k32  =  32_768
    case k128 = 131_072
    case k256 = 262_144

    var id: Int32 { rawValue }

    var label: String {
        switch self {
        case .k8:   return "8K"
        case .k32:  return "32K"
        case .k128: return "128K"
        case .k256: return "256K"
        }
    }

    /// Approximate KV-cache RAM for this context on Gemma 4 12B.
    var kvCacheGB: Double {
        let swaFixed  = 0.335   // 40 SWA layers × 1024 tokens, FP16
        let perToken  = 16_384.0 / 1_073_741_824.0  // 16 KB → GB
        return swaFixed + Double(rawValue) * perToken
    }

    var useCaseLabel: String {
        switch self {
        case .k8:   return "Conversations & quick tasks"
        case .k32:  return "Long articles, code files"
        case .k128: return "Books, large codebases"
        case .k256: return "Maximum — entire novels / repos"
        }
    }

    var speedNote: String {
        switch self {
        case .k8:   return "Fastest"
        case .k32:  return "Fast"
        case .k128: return "Moderate"
        case .k256: return "Slower on long inputs"
        }
    }
}

@MainActor
class ChatEngine: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isGenerating = false
    @Published var isModelLoaded = false
    @Published var loadingStatus = "Loading model..."
    @Published var loadingError: String?
    @Published var thinkingEnabled = true
    @Published var isThinking = false
    static let maxImages = 4   // Google recommends ≤4; each image is 70–1 120 vision tokens depending on resolution
    @Published var pendingImages: [NSImage] = []
    private var pendingImageDatas: [Data] = []
    @Published var pendingAudioSamples: [Float]?
    @Published var pendingAudioDuration: TimeInterval?
    @Published var pendingPDFText: String?
    @Published var pendingPDFName: String?
    @Published var pendingPDFThumbnail: NSImage?
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var isSearching = false
    @Published var searchEnabled = false
    // Quiet mode is the default: ~10-12 t/s keeps the GPU cool and silent,
    // and matches reading speed. Boost (persisted) opts into full speed.
    @Published var boostEnabled = (UserDefaults.standard.object(forKey: "gen.boost") as? Bool) ?? false {
        didSet {
            UserDefaults.standard.set(boostEnabled, forKey: "gen.boost")
            Task { await llama.setBoost(boostEnabled) }
        }
    }
    @Published var contextSizeOption: ContextSizeOption = {
        let raw = UserDefaults.standard.integer(forKey: "ctx.sizeTokens")
        return ContextSizeOption(rawValue: Int32(raw)) ?? .k32
    }() {
        didSet {
            guard !isGenerating else { contextSizeOption = oldValue; return }
            UserDefaults.standard.set(Int(contextSizeOption.rawValue), forKey: "ctx.sizeTokens")
            Task { await reloadContextSize() }
        }
    }
    @Published var tokenCount: Int32 = 0
    @Published var contextSize: Int32 = 32768
    @Published var tokensPerSecond: Double = 0
    @Published var isCompacting = false
    @Published var isTranslating = false
    @Published var translateEnabled = false
    @Published var availableReminderLists: [String] = []

    private var conversationSummary: String?
    /// Compaction fires at 80 % of the current context window.
    private var compactionThreshold: Int32 { Int32(Double(contextSizeOption.rawValue) * 0.8) }
    private let recentMessagesToKeep = 4  // Keep last 2 exchanges (2 user + 2 assistant)

    @Published var currentThreadId: UUID?

    // MARK: - Background generation & message queue

    /// Which thread is currently generating (may differ from currentThreadId when
    /// the user navigates away mid-generation).
    @Published private(set) var generatingThreadId: UUID? = nil

    /// When the user navigates away from the generating thread, its live messages
    /// are stashed here so generation can keep writing without corrupting the
    /// newly-selected thread's messages.
    private var generatingMessages: [ChatMessage] = []
    private var generatingConversationSummary: String? = nil

    /// True only when the thread the user is looking at is the one generating.
    var isViewingGeneratingThread: Bool {
        isGenerating && currentThreadId == generatingThreadId
    }

    /// Messages the user submitted while a generation was already running.
    /// Processed in FIFO order after the current generation completes.
    @Published var messageQueue: [QueuedMessage] = []

    struct QueuedMessage: Identifiable {
        let id = UUID()
        let threadId: UUID
        let text: String
        let images: [NSImage]
        let imageDatas: [Data]
        let audioSamples: [Float]?
        let audioDuration: TimeInterval?
        let pdfText: String?
        let pdfName: String?
        let pdfThumbnail: NSImage?
    }

    private let llama = LlamaEngine()
    private let searchService = WebSearchService()
    private let eventStore = EKEventStore()
    let chatStore = ChatStore()
    private let modelPath: String
    private let mmProjPath: String?

    private var audioEngine: AVAudioEngine?
    private var recordedSamples: [Float] = []
    private var recordingTimer: Timer?
    private var targetSampleRate: Float = 16000
    private var chatStoreCancellable: AnyCancellable?
    private var dockDotCancellable: AnyCancellable?

    /// Set by PendragonApp so the dock-dot can wait for TTS to finish.
    weak var ttsEngine: TTSEngine?

    init() {
        let paths = Self.findModelPaths()
        self.modelPath = paths.model
        self.mmProjPath = paths.mmproj
        // didSet doesn't run for the initial value — push it explicitly
        let boost = boostEnabled
        Task { await llama.setBoost(boost); await loadModel() }

        // Forward chatStore's objectWillChange so SidebarView (which observes
        // ChatEngine) re-renders immediately when threads or pin state changes.
        chatStoreCancellable = chatStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }

        // Clear dock dot whenever the app comes back to the foreground
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Self.setDockDot(false)
        }
    }

    private static func findModelPaths() -> (model: String, mmproj: String?) {
        // NOTE: the QAT Q4_0 build benches ~29% faster (35 vs 27 t/s) but was
        // reverted — in thinking mode it falls into multi-thousand-token
        // reasoning loops that never close the channel, so replies take
        // minutes or come out empty. Q4_K_M behaves correctly.
        let lmStudioDir = NSHomeDirectory() + "/.lmstudio/models/lmstudio-community/gemma-4-12B-it-GGUF"
        let modelPath = lmStudioDir + "/gemma-4-12B-it-Q4_K_M.gguf"
        let mmprojPath = lmStudioDir + "/mmproj-gemma-4-12B-it-BF16.gguf"

        if FileManager.default.fileExists(atPath: modelPath) {
            let mmproj = FileManager.default.fileExists(atPath: mmprojPath) ? mmprojPath : nil
            return (modelPath, mmproj)
        }

        let ollamaBlobs = NSHomeDirectory() + "/.ollama/models/blobs"
        if let files = try? FileManager.default.contentsOfDirectory(atPath: ollamaBlobs) {
            for file in files where file.hasPrefix("sha256-") {
                let path = ollamaBlobs + "/" + file
                let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                if let size = attrs?[.size] as? Int, size > 5_000_000_000 {
                    return (path, nil)
                }
            }
        }

        return (modelPath, FileManager.default.fileExists(atPath: mmprojPath) ? mmprojPath : nil)
    }

    private func loadModel() async {
        do {
            try await llama.loadModel(at: modelPath, mmProjPath: mmProjPath,
                                      n_ctx: contextSizeOption.rawValue)
            isModelLoaded = true
            loadingStatus = "Ready"
            fetchReminderLists()
        } catch {
            loadingError = "Failed to load model: \(error.localizedDescription)\nPath: \(modelPath)"
        }
    }

    // MARK: - Image

    var canAddMoreImages: Bool { pendingImages.count < Self.maxImages }

    func attachImage(from url: URL) {
        guard canAddMoreImages,
              let data = try? Data(contentsOf: url),
              let image = NSImage(data: data) else { return }
        pendingImages.append(image)
        pendingImageDatas.append(data)
    }

    func attachImageFromPasteboard() {
        guard canAddMoreImages else { return }
        let pb = NSPasteboard.general
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
           let image = NSImage(data: data) {
            pendingImages.append(image)
            pendingImageDatas.append(data)
        } else if let items = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
                  let url = items.first,
                  let data = try? Data(contentsOf: url),
                  let image = NSImage(data: data) {
            pendingImages.append(image)
            pendingImageDatas.append(data)
        }
    }

    func removeImage(at index: Int) {
        guard index < pendingImages.count else { return }
        pendingImages.remove(at: index)
        pendingImageDatas.remove(at: index)
    }

    func clearPendingImages() {
        pendingImages.removeAll()
        pendingImageDatas.removeAll()
    }

    func browseForImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            let remaining = Self.maxImages - pendingImages.count
            for url in panel.urls.prefix(remaining) {
                attachImage(from: url)
            }
        }
    }

    // MARK: - PDF

    func attachPDF(from url: URL) {
        guard let document = PDFDocument(url: url) else { return }
        var text = ""
        let pageCount = min(document.pageCount, 50) // Cap at 50 pages
        for i in 0..<pageCount {
            if let page = document.page(at: i), let pageText = page.string {
                text += pageText + "\n"
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 8000 {
            text = String(text.prefix(8000)) + "\n[... truncated, \(document.pageCount) pages total]"
        }
        guard !text.isEmpty else { return }
        pendingPDFText = text
        pendingPDFName = url.lastPathComponent

        // Generate thumbnail from first page
        if let firstPage = document.page(at: 0) {
            let pageRect = firstPage.bounds(for: .mediaBox)
            let scale: CGFloat = 120.0 / max(pageRect.width, pageRect.height)
            let thumbSize = NSSize(width: pageRect.width * scale, height: pageRect.height * scale)
            pendingPDFThumbnail = firstPage.thumbnail(of: thumbSize, for: .mediaBox)
        }
    }

    func clearPendingPDF() {
        pendingPDFText = nil
        pendingPDFName = nil
        pendingPDFThumbnail = nil
    }

    // MARK: - Universal paste

    private static let imageExtensions: Set<String> =
        ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "webp", "heic", "heif"]

    /// Inspect the system clipboard and attach whatever is there.
    /// `appendToInput` is called with formatted text for plain-text / code files.
    /// Returns `true` if something was consumed (the caller should swallow the Cmd+V event).
    @discardableResult
    func pasteFromClipboard(appendToInput: ((String) -> Void)? = nil) -> Bool {
        let pb = NSPasteboard.general

        // 1. File URLs from Finder — MUST be checked before raw image data.
        //    macOS always places a PNG/TIFF thumbnail next to any file URL on the
        //    pasteboard, so checking image data first would treat a PDF (or any
        //    other file) as a plain image attachment.
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: opts) as? [URL],
           !urls.isEmpty {
            var handled = false
            for url in urls {
                let ext = url.pathExtension.lowercased()
                if Self.imageExtensions.contains(ext) {
                    attachImage(from: url)
                    handled = true
                } else if ext == "pdf" {
                    attachPDF(from: url)
                    handled = true
                } else if let raw = try? String(contentsOf: url, encoding: .utf8) {
                    let capped = String(raw.prefix(8_000))
                    let tag    = Self.codeLanguageTag(for: ext)
                    let block  = tag.isEmpty
                        ? "[\(url.lastPathComponent)]\n\(capped)"
                        : "[\(url.lastPathComponent)]\n```\(tag)\n\(capped)\n```"
                    appendToInput?(block)
                    handled = true
                }
            }
            if handled { return true }
        }

        // 2. Raw image data — screenshot or image copied directly from an app/browser
        //    (no file URL present in these cases).
        if canAddMoreImages,
           let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
           NSImage(data: data) != nil {
            attachImageFromPasteboard()
            return true
        }

        return false
    }

    private static func codeLanguageTag(for ext: String) -> String {
        switch ext {
        case "swift":                           return "swift"
        case "py":                              return "python"
        case "js", "mjs", "cjs":               return "javascript"
        case "ts", "tsx":                       return "typescript"
        case "jsx":                             return "jsx"
        case "html", "htm":                     return "html"
        case "css", "scss", "sass":             return "css"
        case "json":                            return "json"
        case "xml":                             return "xml"
        case "sh", "bash", "zsh":              return "bash"
        case "c", "h":                          return "c"
        case "cpp", "cc", "cxx", "hpp":        return "cpp"
        case "java":                            return "java"
        case "kt", "kts":                       return "kotlin"
        case "rb":                              return "ruby"
        case "go":                              return "go"
        case "rs":                              return "rust"
        case "cs":                              return "csharp"
        case "php":                             return "php"
        case "r":                               return "r"
        case "sql":                             return "sql"
        case "yaml", "yml":                     return "yaml"
        case "toml":                            return "toml"
        case "md", "markdown":                  return "markdown"
        default:                                return ""
        }
    }

    // MARK: - Audio

    func browseForAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .wav, .mp3]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            attachAudioFile(from: url)
        }
    }

    func attachAudioFile(from url: URL) {
        guard let audioFile = try? AVAudioFile(forReading: url) else { return }
        let format = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        try? audioFile.read(into: buffer)

        var samples = resampleToTarget(buffer: buffer)
        // Gemma 4 supports max 30 seconds of audio
        let maxSamples = Int(targetSampleRate * 30)
        if samples.count > maxSamples {
            samples = Array(samples.prefix(maxSamples))
        }
        let duration = Double(samples.count) / Double(targetSampleRate)
        pendingAudioSamples = samples
        pendingAudioDuration = duration
    }

    func clearPendingAudio() {
        pendingAudioSamples = nil
        pendingAudioDuration = nil
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        audioEngine = AVAudioEngine()
        guard let audioEngine else { return }

        recordedSamples = []
        recordingDuration = 0

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(targetSampleRate), channels: 1, interleaved: false)!

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else { return }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }

            let ratio = targetSampleRate / Float(inputFormat.sampleRate)
            let outputFrameCount = AVAudioFrameCount(Float(buffer.frameLength) * ratio)
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else { return }

            var error: NSError?
            converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if let channelData = outputBuffer.floatChannelData?[0] {
                let count = Int(outputBuffer.frameLength)
                let samples = Array(UnsafeBufferPointer(start: channelData, count: count))
                Task { @MainActor in
                    self.recordedSamples.append(contentsOf: samples)
                }
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            isRecording = true
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isRecording else { return }
                    self.recordingDuration = Double(self.recordedSamples.count) / Double(self.targetSampleRate)
                    // Gemma 4 supports max 30 seconds of audio
                    if self.recordingDuration >= 30.0 {
                        self.stopRecording()
                    }
                }
            }
        } catch {
            print("Failed to start recording: \(error)")
        }
    }

    private func stopRecording() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        recordingTimer?.invalidate()
        recordingTimer = nil
        isRecording = false

        if !recordedSamples.isEmpty {
            // Hard-cap at 30 s even if the timer fired slightly late
            let maxSamples = Int(targetSampleRate * 30)
            let clamped = recordedSamples.count > maxSamples
                ? Array(recordedSamples.prefix(maxSamples))
                : recordedSamples
            pendingAudioSamples  = clamped
            pendingAudioDuration = Double(clamped.count) / Double(targetSampleRate)
        }
        recordedSamples = []
    }

    private func resampleToTarget(buffer: AVAudioPCMBuffer) -> [Float] {
        let inputFormat = buffer.format
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(targetSampleRate), channels: 1, interleaved: false)!

        if inputFormat.sampleRate == Double(targetSampleRate) && inputFormat.channelCount == 1 {
            if let data = buffer.floatChannelData?[0] {
                return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
            }
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else { return [] }
        let ratio = targetSampleRate / Float(inputFormat.sampleRate)
        let outputFrameCount = AVAudioFrameCount(Float(buffer.frameLength) * ratio)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else { return [] }

        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        if let data = outputBuffer.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: data, count: Int(outputBuffer.frameLength)))
        }
        return []
    }

    // MARK: - Send

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !pendingImages.isEmpty || pendingAudioSamples != nil || pendingPDFText != nil else { return }

        // ── Queue if already generating ──────────────────────────────────────
        if isGenerating {
            messageQueue.append(QueuedMessage(
                threadId: currentThreadId ?? UUID(),
                text: trimmed,
                images: pendingImages, imageDatas: pendingImageDatas,
                audioSamples: pendingAudioSamples, audioDuration: pendingAudioDuration,
                pdfText: pendingPDFText, pdfName: pendingPDFName, pdfThumbnail: pendingPDFThumbnail
            ))
            clearPendingImages(); clearPendingAudio(); clearPendingPDF()
            return
        }

        let images       = pendingImages;     let imageDatas   = pendingImageDatas
        let audioSamples = pendingAudioSamples; let audioDuration = pendingAudioDuration
        let pdfText      = pendingPDFText;    let pdfName      = pendingPDFName
        let pdfThumbnail = pendingPDFThumbnail
        clearPendingImages(); clearPendingAudio(); clearPendingPDF()

        let displayText = trimmed.isEmpty && audioSamples != nil ? "" : trimmed

        messages.append(ChatMessage(role: .user, content: displayText,
                                    images: images, imageDatas: imageDatas,
                                    hasAudio: audioSamples != nil, audioDuration: audioDuration,
                                    pdfName: pdfName, pdfText: pdfText, pdfThumbnail: pdfThumbnail))
        messages.append(ChatMessage(role: .assistant, content: ""))
        isGenerating = true
        isThinking   = thinkingEnabled

        // Assign the thread ID now so selectThread can check it during generation
        let tid = currentThreadId ?? UUID()
        if currentThreadId == nil { currentThreadId = tid }
        generatingThreadId = tid
        // Seed the stash — applyGenerating writes here when the user navigates away
        generatingMessages = messages

        let prompt        = buildPrompt()
        let responseIndex = messages.count - 1
        let thinking      = thinkingEnabled

        Task.detached { [llama, searchService] in
            final class StreamState: @unchecked Sendable {
                var fullRaw = ""; var displayBuf = ""
                var passedThinking: Bool; var tokensSinceFlush = 0
                init(thinking: Bool) { self.passedThinking = !thinking }
            }
            let state = StreamState(thinking: thinking)

            let tokenHandler: @Sendable (String) -> Void = { token in
                state.fullRaw += token
                if !state.passedThinking {
                    if state.fullRaw.contains("<channel|>") {
                        state.passedThinking = true
                        if let range = state.fullRaw.range(of: "<channel|>") {
                            state.displayBuf = String(state.fullRaw[range.upperBound...])
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        let snapshot = state.displayBuf
                        Task { @MainActor in
                            self.isThinking = false
                            self.applyGenerating(tid: tid, index: responseIndex) {
                                var m = $0; m.content = snapshot; return m
                            }
                        }
                    }
                    return
                }
                state.displayBuf += token
                state.tokensSinceFlush += 1
                if state.tokensSinceFlush >= 8 {
                    state.tokensSinceFlush = 0
                    let snapshot = Self.hideStreamingToolSyntax(Self.stripChannelTokens(state.displayBuf))
                    Task { @MainActor in
                        self.applyGenerating(tid: tid, index: responseIndex) {
                            var m = $0; m.content = snapshot; return m
                        }
                    }
                }
            }

            do {
                let result = try await llama.generate(prompt: prompt, imageDatas: imageDatas,
                                                      audioSamples: audioSamples, onToken: tokenHandler)
                // Tool call loop — handles chained calls (e.g. read calendar, then read reminders)
                var currentResult = result
                var toolCallCount = 0
                while case .toolCall(let rawOutput) = currentResult, toolCallCount < 6 {
                    toolCallCount += 1
                    Self.toolDebugLog("tool call #\(toolCallCount) raw output:\n\(rawOutput)\n---")
                    var toolResponse: String?
                    if let query = Self.extractSearchQuery(from: rawOutput), !query.isEmpty {
                        await MainActor.run { self.isSearching = true; self.isThinking = false }
                        let results = await searchService.search(query: query)
                        toolResponse = Self.formatSearchResponse(query: query, results: results)
                        let sources = results.prefix(5).map { (title: $0.title, url: $0.url) }
                        await MainActor.run {
                            self.isSearching = false
                            self.applyGenerating(tid: tid, index: responseIndex) {
                                var m = $0; m.usedWebSearch = true; m.sourceURLs = sources; return m
                            }
                        }
                    } else if let url = Self.extractFetchUrl(from: rawOutput), !url.isEmpty {
                        await MainActor.run { self.isSearching = true; self.isThinking = false }
                        let pageText = await Self.fetchPageText(urlString: url)
                        toolResponse = Self.formatFetchResponse(url: url, content: pageText)
                        let title = pageText.components(separatedBy: "\n")
                            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
                            .prefix(60) ?? Substring(url)
                        await MainActor.run {
                            self.isSearching = false
                            self.applyGenerating(tid: tid, index: responseIndex) {
                                var m = $0
                                m.fetchedURL = url
                                m.sourceURLs = [(title: String(title), url: url)]
                                return m
                            }
                        }
                    } else if let calParams = Self.extractCalendarEventCall(from: rawOutput) {
                        let store = await MainActor.run { self.eventStore }
                        toolResponse = await Self.performCalendarEvent(calParams, store: store)
                        Self.toolDebugLog("calendar result: \(toolResponse ?? "nil")")
                    } else if let remParams = Self.extractCreateReminderCall(from: rawOutput) {
                        let store = await MainActor.run { self.eventStore }
                        toolResponse = await Self.performCreateReminder(remParams, store: store)
                    } else if rawOutput.contains("list_calendar_events") {
                        let store = await MainActor.run { self.eventStore }
                        toolResponse = await Self.performListCalendarEvents(rawOutput, store: store)
                    } else if rawOutput.contains("list_reminders") {
                        let store = await MainActor.run { self.eventStore }
                        toolResponse = await Self.performListReminders(rawOutput, store: store)
                    } else if rawOutput.contains("run_python") {
                        toolResponse = await Self.performRunPython(rawOutput)
                    }
                    // If no extractor recognised the call, don't silently stop (that
                    // leaves an empty bubble and the action never happens) — tell the
                    // model its call was malformed so it can retry or answer in text.
                    let resp = toolResponse ??
                        "<|tool_response>response:error{message:<|\"|>Tool call not understood — check the tool name and that all arguments use the declared format, then try again or answer directly.<|\"|>}<tool_response|>"
                    if toolResponse == nil {
                        Self.toolDebugLog("NO EXTRACTOR MATCHED — sent malformed-call response back to model")
                    }
                    state.fullRaw = ""; state.displayBuf = ""
                    state.passedThinking = true; state.tokensSinceFlush = 0
                    currentResult = try await llama.continueGeneration(text: resp, onToken: tokenHandler)
                }

                var visible = Self.extractVisibleText(from: state.fullRaw, thinkingEnabled: thinking)
                if visible.isEmpty && !state.fullRaw.isEmpty {
                    // The model ended its turn while still inside the thinking
                    // block (no <channel|> close). Show the cleaned reasoning
                    // text rather than an empty bubble.
                    visible = Self.extractVisibleText(from: state.fullRaw, thinkingEnabled: false)
                }
                let (cleanText, vizCode) = Self.extractVisualization(from: visible)
                await MainActor.run {
                    self.applyGenerating(tid: tid, index: responseIndex) {
                        var m = $0; m.content = cleanText; return m
                    }
                    if let vizCode {
                        self.applyGenerating(tid: tid, index: responseIndex) {
                            var m = $0; m.hasVisualization = true; m.visualizationCode = vizCode; return m
                        }
                        VisualizationWindowManager.shared.openVisualization(code: vizCode)
                    }
                }
            } catch {
                let msg = "\n[Error: \(error.localizedDescription)]"
                await MainActor.run {
                    self.applyGenerating(tid: tid, index: responseIndex) {
                        var m = $0; m.content += msg; return m
                    }
                }
            }

            let finalTokenCount = await llama.tokenCount
            let ctxSize         = await llama.contextSize
            let tps             = await llama.tokensPerSecond
            await MainActor.run {
                self.isGenerating = false
                self.isThinking   = false
                self.isSearching  = false
                self.tokenCount   = finalTokenCount
                self.contextSize  = ctxSize
                self.tokensPerSecond = tps

                // Free raw image bytes from the user message — they were already passed
                // to generate() via the captured local; only the display NSImage is needed.
                let userIdx = responseIndex - 1
                if userIdx >= 0 && userIdx < self.messages.count {
                    self.messages[userIdx].imageDatas = []
                }

                if !NSApp.isActive {
                    self.showDockDotAfterTTS()
                }
                self.saveCurrentThread()
                self.generatingThreadId = nil
                self.generatingMessages = []
                self.generatingConversationSummary = nil
                // Compact BEFORE processing queue so the guard (!isGenerating) passes.
                // After compaction finishes it calls processQueueForThread itself.
                if finalTokenCount > self.compactionThreshold {
                    self.compactConversation(thenProcessQueueFor: tid)
                } else {
                    self.processQueueForThread(tid)
                }
            }
        }
    }

    /// Routes a message mutation to the correct messages array.
    /// When the user is looking at the generating thread, `messages` is live.
    /// When they've navigated away, `generatingMessages` holds the stash.
    @MainActor
    private func applyGenerating(tid: UUID, index: Int, _ f: (ChatMessage) -> ChatMessage) {
        if currentThreadId == tid {
            guard index < messages.count else { return }
            messages[index] = f(messages[index])
        } else {
            guard index < generatingMessages.count else { return }
            generatingMessages[index] = f(generatingMessages[index])
        }
    }

    /// Send the next queued message for `tid` if the user is currently viewing that thread.
    @MainActor
    private func processQueueForThread(_ tid: UUID) {
        guard let idx = messageQueue.firstIndex(where: { $0.threadId == tid }) else { return }
        let qm = messageQueue.remove(at: idx)
        if currentThreadId == tid {
            pendingImages       = qm.images
            pendingImageDatas   = qm.imageDatas
            pendingAudioSamples = qm.audioSamples
            pendingAudioDuration = qm.audioDuration
            pendingPDFText      = qm.pdfText
            pendingPDFName      = qm.pdfName
            pendingPDFThumbnail = qm.pdfThumbnail
            send(qm.text)
        } else {
            // User navigated away — put it back, will fire when they return
            messageQueue.insert(qm, at: 0)
        }
    }

    // MARK: - Thread Management

    private func saveCurrentThread() {
        // When the user has navigated away from the generating thread, save the
        // stash (generatingMessages) not the currently-displayed thread's messages.
        if let gtid = generatingThreadId,
           gtid != currentThreadId,
           !generatingMessages.isEmpty {
            let storedMessages = generatingMessages.map { ChatStore.toStored($0) }
            let title = ChatStore.generateTitle(from: generatingMessages)
            let thread = ChatThread(
                id: gtid, title: title, messages: storedMessages,
                createdAt: chatStore.threads.first(where: { $0.id == gtid })?.createdAt ?? Date(),
                updatedAt: Date(),
                conversationSummary: generatingConversationSummary
            )
            chatStore.saveThread(thread)
            return
        }

        guard !messages.isEmpty else { return }
        let storedMessages = messages.map { ChatStore.toStored($0) }
        let title = ChatStore.generateTitle(from: messages)
        let thread = ChatThread(
            id: currentThreadId ?? UUID(),
            title: title,
            messages: storedMessages,
            createdAt: chatStore.threads.first(where: { $0.id == currentThreadId })?.createdAt ?? Date(),
            updatedAt: Date(),
            conversationSummary: conversationSummary
        )
        if currentThreadId == nil { currentThreadId = thread.id }
        chatStore.saveThread(thread)
    }

    func selectThread(_ thread: ChatThread) {
        guard thread.id != currentThreadId else { return }

        // Save whatever is currently displayed before switching
        saveCurrentThread()

        if isGenerating {
            if currentThreadId == generatingThreadId {
                // Leaving the generating thread — stash its live messages
                generatingMessages            = messages
                generatingConversationSummary = conversationSummary
            }
            if thread.id == generatingThreadId {
                // Returning to the generating thread — restore live messages
                messages            = generatingMessages
                conversationSummary = generatingConversationSummary
                generatingMessages  = []
                generatingConversationSummary = nil
            } else {
                // Switching to a neutral (non-generating) thread
                messages            = thread.messages.map { ChatStore.fromStored($0) }
                conversationSummary = thread.conversationSummary
            }
            // Don't clear llama — generation is still running
        } else {
            messages            = thread.messages.map { ChatStore.fromStored($0) }
            conversationSummary = thread.conversationSummary
            Task { await llama.clear() }
        }

        currentThreadId = thread.id
        tokenCount = 0
        clearPendingImages()
        clearPendingAudio()
        if isRecording { stopRecording() }

        // If there's a queued message for this thread and we're not generating, send it
        if !isGenerating {
            processQueueForThread(thread.id)
        }
    }

    func deleteThread(_ thread: ChatThread) {
        chatStore.deleteThread(thread)
        if currentThreadId == thread.id {
            messages.removeAll()
            currentThreadId = nil
            conversationSummary = nil
            tokenCount = 0
            Task { await llama.clear() }
        }
    }

    func togglePin(_ thread: ChatThread) {
        chatStore.togglePin(thread)
    }

    /// Extract threejs code block from output, returning cleaned text and the code.
    /// Handles both complete (closed ```) blocks and unclosed blocks (generation ended mid-block).
    private nonisolated static func extractVisualization(from text: String) -> (String, String?) {
        // Complete block: ```threejs\n...\n```
        let completePattern = #"```threejs\s*\n([\s\S]*?)```"#
        if let regex = try? NSRegularExpression(pattern: completePattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let codeRange = Range(match.range(at: 1), in: text),
           let fullRange = Range(match.range, in: text) {
            let code = String(text[codeRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            var cleaned = text
            cleaned.replaceSubrange(fullRange, with: "")
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            return (cleaned, code.isEmpty ? nil : code)
        }
        // Unclosed block: ```threejs\n... (generation ended before the closing ```)
        let openPattern = #"```threejs\s*\n([\s\S]+)"#
        if let regex = try? NSRegularExpression(pattern: openPattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let codeRange = Range(match.range(at: 1), in: text),
           let fullRange = Range(match.range, in: text) {
            let code = String(text[codeRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            var cleaned = text
            cleaned.replaceSubrange(fullRange, with: "")
            // Strip the opening fence too
            cleaned = cleaned.replacingOccurrences(of: "```threejs", with: "")
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            return (cleaned, code.isEmpty ? nil : code)
        }
        return (text, nil)
    }

    /// Extract the user-visible text from raw model output, stripping thinking and tool tokens
    nonisolated static func extractVisibleText(from raw: String, thinkingEnabled: Bool) -> String {
        var text = raw

        // Strip thinking block: everything from start up to and including <channel|>
        if thinkingEnabled {
            if let range = text.range(of: "<channel|>") {
                text = String(text[range.upperBound...])
            } else if text.contains("<|channel>") {
                // Still inside thinking block, show nothing yet
                return ""
            }
        }

        // Strip channel tokens that might appear without thinking
        text = stripChannelTokens(text)

        // Strip tool call/response markup
        text = stripToolTokens(text)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reload the llama context with the currently selected n_ctx.
    /// Model weights stay in memory — only the KV cache is rebuilt.
    /// Clears the conversation because the KV cache is reset.
    private func reloadContextSize() async {
        let nCtx = contextSizeOption.rawValue
        isModelLoaded = false
        loadingStatus = "Resizing context to \(contextSizeOption.label)…"
        do {
            try await llama.reloadContext(n_ctx: nCtx)
            messages.removeAll()
            currentThreadId = nil
            tokenCount = await llama.tokenCount
            contextSize = await llama.contextSize
            isModelLoaded = true
        } catch {
            loadingError = "Context resize failed: \(error.localizedDescription)"
            isModelLoaded = true
        }
    }

    /// Awaited by AppDelegate.applicationShouldTerminate so the llama backend
    /// is fully torn down before exit() fires C++ static destructors.
    func shutdownForTermination() async {
        if isRecording { stopRecording() }
        // llama is an actor — this call serialises behind any running generate(),
        // waits for it to return, then frees context/model/backend.
        await llama.shutdown()
    }

    func cleanup() {
        if isRecording { stopRecording() }
        Task { await llama.shutdown() }
    }

    func newChat() {
        // Allowed even during generation — stash the generating thread so it
        // continues in the background, exactly like selectThread() does.
        saveCurrentThread()
        if isGenerating {
            if currentThreadId == generatingThreadId {
                generatingMessages            = messages
                generatingConversationSummary = conversationSummary
            }
            // Don't clear llama — generation is still running
        } else {
            Task { await llama.clear() }
        }
        messages.removeAll()
        currentThreadId = nil
        clearPendingImages()
        clearPendingAudio()
        if isRecording { stopRecording() }
        tokenCount = 0
        conversationSummary = nil
    }

    func stopGenerating() {
        llama.stop()
    }

    // MARK: - Translation

    /// Runs a one-shot translation request through the local model without
    /// touching the conversation context.  Clears the KV cache before and
    /// after so the conversation is not polluted.
    func translateText(_ text: String, completion: @escaping (String) -> Void) {
        guard !isGenerating, !isTranslating, !text.isEmpty else {
            completion("")
            return
        }
        isTranslating = true

        let prompt = Self.buildTranslationPrompt(text)

        Task.detached { [llama] in
            var raw = ""
            do {
                let _ = try await llama.generate(
                    prompt: prompt,
                    imageDatas: [],
                    audioSamples: nil,
                    onToken: { token in raw += token }
                )
            } catch {
                raw = "[Translation error: \(error.localizedDescription)]"
            }

            // Reset KV cache so the next conversation send rebuilds cleanly
            await llama.clear()

            let result = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            await MainActor.run {
                self.isTranslating = false
                completion(result)
            }
        }
    }

    private nonisolated static func buildTranslationPrompt(_ text: String) -> String {
        """
        <|turn>system
        You are a precise translator. Given a message in any language, reply with ONLY these three sections and nothing else:

        **Original:** [copy the original message verbatim]

        **Translation:** [natural, fluent English translation]

        **Word for word:** [literal word-by-word gloss; for every inflected verb write: conjugated_form (→ infinitive)]
        <turn|>
        <|turn>user
        \(text)
        <turn|>
        <|turn>model

        """
    }

    // MARK: - Compaction

    private func compactConversation(thenProcessQueueFor tid: UUID? = nil) {
        guard !isGenerating, messages.count > recentMessagesToKeep else {
            if let tid { processQueueForThread(tid) }
            return
        }
        isCompacting = true
        isGenerating = true

        // Split: older messages to summarize, recent ones to keep
        let splitIndex = max(0, messages.count - recentMessagesToKeep)
        let olderMessages = Array(messages.prefix(splitIndex))
        let recentMessages = Array(messages.suffix(recentMessagesToKeep))

        // Build a summarization prompt
        var summaryPrompt = "<|turn>system\nYou are a summarizer. Condense the following conversation into a brief summary (2-4 sentences). Preserve key facts, decisions, and context that would be needed to continue the conversation naturally. Only output the summary, nothing else.<turn|>\n"
        summaryPrompt += "<|turn>user\n"

        if let existingSummary = conversationSummary {
            summaryPrompt += "Previous summary: \(existingSummary)\n\n"
        }
        summaryPrompt += "Conversation to summarize:\n"
        for msg in olderMessages {
            let role = msg.role == .user ? "User" : "Assistant"
            // Strip thinking blocks so the summariser sees only final answers
            let content = msg.role == .assistant
                ? Self.stripThinkingBlocks(msg.content)
                : msg.content
            if !content.isEmpty {
                summaryPrompt += "\(role): \(content)\n"
            }
        }
        summaryPrompt += "<turn|>\n<|turn>model\n"

        Task.detached { [llama] in
            do {
                var summaryText = ""
                let _ = try await llama.generate(
                    prompt: summaryPrompt,
                    imageDatas: [],
                    audioSamples: nil,
                    onToken: { token in
                        summaryText += token
                    }
                )

                // Clean up the summary
                let cleaned = summaryText.trimmingCharacters(in: .whitespacesAndNewlines)

                await MainActor.run {
                    if !cleaned.isEmpty {
                        self.conversationSummary = cleaned
                        self.messages = recentMessages
                    }
                    // Clear KV cache so next generate() rebuilds from the compact prompt
                    Task {
                        await llama.clear()
                        let count = await llama.tokenCount
                        await MainActor.run {
                            self.tokenCount = count
                            self.isCompacting = false
                            self.isGenerating = false
                            // Resume any queued message now that compaction is done
                            if let tid { self.processQueueForThread(tid) }
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.isCompacting = false
                    self.isGenerating = false
                    if let tid { self.processQueueForThread(tid) }
                }
            }
        }
    }

    // MARK: - Prompt

    private func buildPrompt() -> String {
        var prompt = "<|turn>system\n"
        if thinkingEnabled {
            prompt += "<|think|>"
        }
        if translateEnabled {
            prompt += "You are a precise translator. For every user message, respond ONLY with these three sections and nothing else:\n**Original:** [copy the original message verbatim]\n**Translation:** [natural, fluent English translation]\n**Word for word:** [literal word-by-word gloss; for every inflected verb write: conjugated_form (→ infinitive, meaning)]"
        } else {
            prompt += "You are Pendragon, a helpful assistant."
            prompt += "\nYou can create interactive 3D visualizations. When the user asks for a visual demonstration, graph, or explainer of a concept, write a Three.js code block using ```threejs. This opens in a separate window. THREE is already loaded as a global (do NOT write import statements). OrbitControls is also available as the global `OrbitControls` — do NOT use `THREE.OrbitControls`, use `OrbitControls` directly (e.g. `new OrbitControls(camera, renderer.domElement)`). Write complete code: create scene, camera, renderer (THREE.WebGLRenderer), objects, lights, and an animation loop with requestAnimationFrame. Append renderer.domElement to document.body. Use window.innerWidth/innerHeight for size and dark background 0x1C1C1E. ALWAYS include your own resize handler: window.addEventListener('resize', ...) that updates camera.aspect and renderer.setSize. Keep code self-contained, no external assets."
        }
        if let summary = conversationSummary {
            prompt += "\n\n[Earlier conversation summary: \(summary)]"
        }
        // Check if the latest user message contains a URL
        let lastUserMsg = messages.last(where: { $0.role == .user })?.content ?? ""
        let hasURL = lastUserMsg.range(of: #"https?://\S+"#, options: .regularExpression) != nil

        prompt += "\nYou have access to tools. Today's date is \(Self.todayString())."
        if searchEnabled || hasURL {
            if searchEnabled {
                prompt += "\nFor EVERY user message you MUST call web_search first before answering — no exceptions, even if you think you know the answer. Always search, then answer based on the fresh results."
            }
            if hasURL {
                prompt += "\nThe user provided a URL. You MUST use fetch_url to retrieve its content before responding."
            }
            prompt += "\n<|tool>declaration:web_search{description:<|\"|>Search the web for current information<|\"|>,parameters:{properties:{query:{description:<|\"|>The search query<|\"|>,type:<|\"|>STRING<|\"|>}},required:[<|\"|>query<|\"|>],type:<|\"|>OBJECT<|\"|>}}<tool|>"
            prompt += "\n<|tool>declaration:fetch_url{description:<|\"|>Fetch and read the content of a web page URL<|\"|>,parameters:{properties:{url:{description:<|\"|>The URL to fetch<|\"|>,type:<|\"|>STRING<|\"|>}},required:[<|\"|>url<|\"|>],type:<|\"|>OBJECT<|\"|>}}<tool|>"
        }
        prompt += "\n<|tool>declaration:list_calendar_events{description:<|\"|>Read upcoming or past events from Apple Calendar<|\"|>,parameters:{properties:{start_date:{description:<|\"|>Start of date range in ISO 8601 format (default: today)<|\"|>,type:<|\"|>STRING<|\"|>},end_date:{description:<|\"|>End of date range in ISO 8601 format (default: 7 days from start)<|\"|>,type:<|\"|>STRING<|\"|>},calendar:{description:<|\"|>Calendar name to filter by (optional, default: all calendars)<|\"|>,type:<|\"|>STRING<|\"|>}},required:[],type:<|\"|>OBJECT<|\"|>}}<tool|>"
        prompt += "\n<|tool>declaration:list_reminders{description:<|\"|>Read reminders from Apple Reminders<|\"|>,parameters:{properties:{list:{description:<|\"|>Reminder list name to read (optional, default: all lists)<|\"|>,type:<|\"|>STRING<|\"|>},include_completed:{description:<|\"|>Include completed reminders (default: false)<|\"|>,type:<|\"|>STRING<|\"|>}},required:[],type:<|\"|>OBJECT<|\"|>}}<tool|>"
        prompt += "\n<|tool>declaration:create_calendar_event{description:<|\"|>Create an event in Apple Calendar<|\"|>,parameters:{properties:{title:{description:<|\"|>Event title<|\"|>,type:<|\"|>STRING<|\"|>},start_date:{description:<|\"|>Start date/time in ISO 8601 format, e.g. 2025-06-10T14:00:00<|\"|>,type:<|\"|>STRING<|\"|>},end_date:{description:<|\"|>End date/time in ISO 8601 format (optional, defaults to 1 hour after start)<|\"|>,type:<|\"|>STRING<|\"|>},location:{description:<|\"|>Optional location or address for the event<|\"|>,type:<|\"|>STRING<|\"|>},notes:{description:<|\"|>Optional notes or description<|\"|>,type:<|\"|>STRING<|\"|>}},required:[<|\"|>title<|\"|>,<|\"|>start_date<|\"|>],type:<|\"|>OBJECT<|\"|>}}<tool|>"
        // Reminder tool — always available; list names are injected so the model can pick the right one
        if !availableReminderLists.isEmpty {
            let listNames = availableReminderLists.map { "\"\($0)\"" }.joined(separator: ", ")
            prompt += "\nAvailable Reminder lists: \(listNames). When creating a reminder, pick the most appropriate list. If uncertain, ask the user by listing the candidates."
        }
        prompt += "\n<|tool>declaration:create_reminder{description:<|\"|>Add a reminder to Apple Reminders<|\"|>,parameters:{properties:{title:{description:<|\"|>Reminder title or task description<|\"|>,type:<|\"|>STRING<|\"|>},list:{description:<|\"|>Name of the Reminder list to add it to (use one of the available lists)<|\"|>,type:<|\"|>STRING<|\"|>},due_date:{description:<|\"|>Optional due date/time in ISO 8601 format, e.g. 2025-06-10T09:00:00<|\"|>,type:<|\"|>STRING<|\"|>},notes:{description:<|\"|>Optional extra notes<|\"|>,type:<|\"|>STRING<|\"|>}},required:[<|\"|>title<|\"|>],type:<|\"|>OBJECT<|\"|>}}<tool|>"
        prompt += "\nFor non-trivial calculations (finance, statistics, physics, geometry, etc.) use run_python to get an accurate result rather than computing by hand. Always print() your results."
        prompt += "\n<|tool>declaration:run_python{description:<|\"|>Execute a Python 3 script and return its output. Use for any non-trivial calculation.<|\"|>,parameters:{properties:{code:{description:<|\"|>Complete Python 3 script. Use print() for all output.<|\"|>,type:<|\"|>STRING<|\"|>}},required:[<|\"|>code<|\"|>],type:<|\"|>OBJECT<|\"|>}}<tool|>"
        prompt += "<turn|>\n"

        for msg in messages {
            switch msg.role {
            case .user:
                var userContent = msg.content
                // Inject PDF text into the prompt so the model can read it
                if let pdfText = msg.pdfText {
                    let label = msg.pdfName ?? "document.pdf"
                    let pdfBlock = "[PDF: \(label)]\n\(pdfText)\n[End PDF]"
                    if userContent.isEmpty {
                        userContent = pdfBlock
                    } else {
                        userContent = pdfBlock + "\n\n" + userContent
                    }
                }
                prompt += "<|turn>user\n\(userContent)<turn|>\n"
            case .assistant:
                // Per Gemma 4 model card: historical assistant turns must NOT contain
                // thinking blocks — strip them defensively even if already cleaned.
                let historyContent = Self.stripThinkingBlocks(msg.content)
                if !historyContent.isEmpty {
                    prompt += "<|turn>model\n\(historyContent)<turn|>\n"
                }
            }
        }
        prompt += "<|turn>model\n"
        return prompt
    }

    /// Shows the dock dot once TTS synthesis drains, or immediately if TTS is idle.
    /// Deferred by one main-queue cycle so ChatView's .onChange has time to call
    /// synthesizeBackground before we check synthesizingIds.
    private func showDockDotAfterTTS() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            guard let tts = self.ttsEngine, !tts.synthesizingIds.isEmpty else {
                Self.setDockDot(true)
                return
            }
            self.dockDotCancellable = tts.$synthesizingIds
                .filter { $0.isEmpty }
                .first()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard !NSApp.isActive else { return }
                    Self.setDockDot(true)
                    self?.dockDotCancellable = nil
                }
        }
    }

    /// Draws a small red notification dot on the dock icon (half the size of the
    /// system badge) or restores the plain icon when `show` is false.
    nonisolated static func setDockDot(_ show: Bool) {
        DispatchQueue.main.async {
            if show {
                let size = NSSize(width: 128, height: 128)
                let image = NSImage(size: size, flipped: false) { rect in
                    // App icon
                    if let icon = NSApp.applicationIconImage {
                        icon.draw(in: rect)
                    }
                    // Small dot — ~18 pt radius, top-right corner
                    let dotD: CGFloat = 36
                    let dotRect = NSRect(x: rect.maxX - dotD - 4,
                                        y: rect.maxY - dotD - 4,
                                        width: dotD, height: dotD)
                    NSColor.red.setFill()
                    NSBezierPath(ovalIn: dotRect).fill()
                    return true
                }
                NSApp.dockTile.contentView = NSImageView(image: image)
                NSApp.dockTile.display()
            } else {
                NSApp.dockTile.contentView = nil
                NSApp.dockTile.display()
            }
        }
    }

    private nonisolated static func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    // MARK: - Tool Calling Helpers

    // MARK: - Tool debug log

    /// Appends to Application Support/Pendragon/tool-debug.log — tool calls are
    /// invisible in the UI, so failures (parse miss, access denied) need a trail.
    nonisolated static func toolDebugLog(_ s: String) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pendragon", isDirectory: true)
        let url = dir.appendingPathComponent("tool-debug.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            try? line.data(using: .utf8)!.write(to: url)
        }
    }

    // MARK: - Calendar Tool

    struct CalendarEventParams: Sendable {
        let title: String
        let startDate: String
        let endDate: String?
        let location: String?
        let notes: String?
    }

    nonisolated static func extractCalendarEventCall(from rawOutput: String) -> CalendarEventParams? {
        guard rawOutput.contains("create_calendar_event") else { return nil }

        func extractField(_ field: String) -> String? {
            let patterns = [
                "\(field):<\\|\"\\|>(.*?)<\\|\"\\|>",
                "\(field):\"(.*?)\"",
                "\(field):'(.*?)'",
            ]
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
                      let match = regex.firstMatch(in: rawOutput, range: NSRange(rawOutput.startIndex..., in: rawOutput)),
                      match.numberOfRanges > 1,
                      let range = Range(match.range(at: 1), in: rawOutput) else { continue }
                let val = String(rawOutput[range])
                    .replacingOccurrences(of: "<|\"|>", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !val.isEmpty { return val }
            }
            return nil
        }

        guard let startDate = extractField("start_date") else { return nil }
        // Gemma 12B often puts the event name in `notes` (or omits `title` entirely)
        // — observed live in tool-debug.log. Fall back so the call still succeeds.
        let notes = extractField("notes")
        guard let title = extractField("title") ?? notes else { return nil }
        return CalendarEventParams(
            title: title,
            startDate: startDate,
            endDate: extractField("end_date"),
            location: extractField("location"),
            notes: extractField("title") == nil ? nil : notes
        )
    }

    private nonisolated static func performCalendarEvent(
        _ params: CalendarEventParams,
        store: EKEventStore
    ) async -> String {
        return await withCheckedContinuation { continuation in
            let requestAccess: (@escaping (Bool, Error?) -> Void) -> Void
            if #available(macOS 14.0, *) {
                requestAccess = { store.requestFullAccessToEvents(completion: $0) }
            } else {
                requestAccess = { store.requestAccess(to: .event, completion: $0) }
            }

            requestAccess { granted, error in
                guard granted, error == nil else {
                    let msg = error?.localizedDescription ?? "access denied"
                    continuation.resume(returning:
                        "<|tool_response>response:create_calendar_event{error:<|\"|>Calendar access denied: \(msg)<|\"|>}<tool_response|>"
                    )
                    return
                }

                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate,
                                     .withColonSeparatorInTime, .withTimeZone]

                // Try multiple date formats
                let formatters: [() -> Date?] = [
                    { iso.date(from: params.startDate) },
                    {
                        let f = DateFormatter()
                        f.locale = Locale(identifier: "en_US_POSIX")
                        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                        return f.date(from: params.startDate)
                    },
                    {
                        let f = DateFormatter()
                        f.locale = Locale(identifier: "en_US_POSIX")
                        f.dateFormat = "yyyy-MM-dd HH:mm"
                        return f.date(from: params.startDate)
                    },
                ]

                var startDate: Date?
                for fmt in formatters {
                    if let d = fmt() { startDate = d; break }
                }

                guard let start = startDate else {
                    continuation.resume(returning:
                        "<|tool_response>response:create_calendar_event{error:<|\"|>Could not parse start date '\(params.startDate)'. Use ISO 8601 format e.g. 2025-06-10T14:00:00<|\"|>}<tool_response|>"
                    )
                    return
                }

                var endDate: Date = start.addingTimeInterval(3600)
                if let endStr = params.endDate {
                    let endFmt = DateFormatter()
                    endFmt.locale = Locale(identifier: "en_US_POSIX")
                    endFmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                    if let d = iso.date(from: endStr) {
                        endDate = d
                    } else if let d = endFmt.date(from: endStr) {
                        endDate = d
                    }
                }

                let event = EKEvent(eventStore: store)
                event.title = params.title
                event.startDate = start
                event.endDate = endDate
                event.location = params.location
                event.notes = params.notes
                event.calendar = store.defaultCalendarForNewEvents

                do {
                    try store.save(event, span: .thisEvent)
                    let df = DateFormatter()
                    df.dateStyle = .medium
                    df.timeStyle = .short
                    let startStr = df.string(from: start)
                    let locStr = params.location.map { " at \($0)" } ?? ""
                    continuation.resume(returning:
                        "<|tool_response>response:create_calendar_event{success:<|\"|>Event '\(params.title)' created on \(startStr)\(locStr)<|\"|>}<tool_response|>"
                    )
                } catch {
                    continuation.resume(returning:
                        "<|tool_response>response:create_calendar_event{error:<|\"|>\(error.localizedDescription)<|\"|>}<tool_response|>"
                    )
                }
            }
        }
    }

    // MARK: - Reminders Tool

    private struct ReminderParams: Sendable {
        let title: String
        let list: String?
        let dueDate: String?
        let notes: String?
    }

    private nonisolated static func extractCreateReminderCall(from rawOutput: String) -> ReminderParams? {
        guard rawOutput.contains("create_reminder") else { return nil }

        func extractField(_ field: String) -> String? {
            let patterns = [
                "\(field):<\\|\"\\|>(.*?)<\\|\"\\|>",
                "\(field):\"(.*?)\"",
                "\(field):'(.*?)'",
            ]
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
                      let match = regex.firstMatch(in: rawOutput, range: NSRange(rawOutput.startIndex..., in: rawOutput)),
                      match.numberOfRanges > 1,
                      let range = Range(match.range(at: 1), in: rawOutput) else { continue }
                let val = String(rawOutput[range])
                    .replacingOccurrences(of: "<|\"|>", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !val.isEmpty { return val }
            }
            return nil
        }

        guard let title = extractField("title") else { return nil }
        return ReminderParams(
            title: title,
            list: extractField("list"),
            dueDate: extractField("due_date"),
            notes: extractField("notes")
        )
    }

    private nonisolated static func performCreateReminder(
        _ params: ReminderParams,
        store: EKEventStore
    ) async -> String {
        return await withCheckedContinuation { continuation in
            let requestAccess: (@escaping (Bool, Error?) -> Void) -> Void
            if #available(macOS 14.0, *) {
                requestAccess = { store.requestFullAccessToReminders(completion: $0) }
            } else {
                requestAccess = { store.requestAccess(to: .reminder, completion: $0) }
            }

            requestAccess { granted, error in
                guard granted, error == nil else {
                    let msg = error?.localizedDescription ?? "access denied"
                    continuation.resume(returning:
                        "<|tool_response>response:create_reminder{error:<|\"|>Reminders access denied: \(msg)<|\"|>}<tool_response|>"
                    )
                    return
                }

                // Find the target list
                let allLists = store.calendars(for: .reminder)
                var targetList: EKCalendar? = store.defaultCalendarForNewReminders()

                if let listName = params.list, !listName.isEmpty {
                    // Exact match first, then case-insensitive, then fuzzy contains
                    if let exact = allLists.first(where: { $0.title == listName }) {
                        targetList = exact
                    } else if let ci = allLists.first(where: { $0.title.lowercased() == listName.lowercased() }) {
                        targetList = ci
                    } else if let fuzzy = allLists.first(where: {
                        $0.title.lowercased().contains(listName.lowercased()) ||
                        listName.lowercased().contains($0.title.lowercased())
                    }) {
                        targetList = fuzzy
                    }
                }

                let reminder = EKReminder(eventStore: store)
                reminder.title = params.title
                reminder.notes = params.notes
                reminder.calendar = targetList

                // Parse due date
                if let dueDateStr = params.dueDate {
                    let iso = ISO8601DateFormatter()
                    iso.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate,
                                         .withColonSeparatorInTime, .withTimeZone]
                    let fallback = DateFormatter()
                    fallback.locale = Locale(identifier: "en_US_POSIX")
                    fallback.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"

                    if let d = iso.date(from: dueDateStr) ?? fallback.date(from: dueDateStr) {
                        var comps = Calendar.current.dateComponents(
                            [.year, .month, .day, .hour, .minute, .second], from: d)
                        comps.timeZone = TimeZone.current
                        reminder.dueDateComponents = comps
                    }
                }

                do {
                    try store.save(reminder, commit: true)
                    let listName = targetList?.title ?? "Reminders"
                    continuation.resume(returning:
                        "<|tool_response>response:create_reminder{success:<|\"|>Reminder '\(params.title)' added to '\(listName)'<|\"|>}<tool_response|>"
                    )
                } catch {
                    continuation.resume(returning:
                        "<|tool_response>response:create_reminder{error:<|\"|>\(error.localizedDescription)<|\"|>}<tool_response|>"
                    )
                }
            }
        }
    }

    /// Fetches reminder list names and caches them so buildPrompt can include them.
    func fetchReminderLists() {
        let requestAccess: (@escaping (Bool, Error?) -> Void) -> Void
        if #available(macOS 14.0, *) {
            requestAccess = { [eventStore] in eventStore.requestFullAccessToReminders(completion: $0) }
        } else {
            requestAccess = { [eventStore] in eventStore.requestAccess(to: .reminder, completion: $0) }
        }
        requestAccess { [weak self, eventStore] granted, _ in
            guard granted, let self else { return }
            let names = eventStore.calendars(for: .reminder).map { $0.title }.sorted()
            DispatchQueue.main.async { self.availableReminderLists = names }
        }
    }

    // MARK: - Read Calendar Events

    private nonisolated static func performListCalendarEvents(
        _ rawOutput: String,
        store: EKEventStore
    ) async -> String {
        return await withCheckedContinuation { continuation in
            let requestAccess: (@escaping (Bool, Error?) -> Void) -> Void
            if #available(macOS 14.0, *) {
                requestAccess = { store.requestFullAccessToEvents(completion: $0) }
            } else {
                requestAccess = { store.requestAccess(to: .event, completion: $0) }
            }
            requestAccess { granted, error in
                guard granted else {
                    continuation.resume(returning:
                        "<|tool_response>response:list_calendar_events{error:<|\"|>Calendar access denied<|\"|>}<tool_response|>"
                    )
                    return
                }

                // Parse requested date range
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate,
                                     .withColonSeparatorInTime, .withTimeZone]
                let fallback: (String) -> Date? = { str in
                    let f = DateFormatter()
                    f.locale = Locale(identifier: "en_US_POSIX")
                    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                    return f.date(from: str) ?? {
                        let f2 = DateFormatter()
                        f2.locale = Locale(identifier: "en_US_POSIX")
                        f2.dateFormat = "yyyy-MM-dd"
                        return f2.date(from: str)
                    }()
                }

                func extractField(_ field: String) -> String? {
                    let patterns = ["\(field):<\\|\"\\|>(.*?)<\\|\"\\|>", "\(field):\"(.*?)\""]
                    for pattern in patterns {
                        guard let regex = try? NSRegularExpression(pattern: pattern),
                              let match = regex.firstMatch(in: rawOutput, range: NSRange(rawOutput.startIndex..., in: rawOutput)),
                              let range = Range(match.range(at: 1), in: rawOutput) else { continue }
                        return String(rawOutput[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    return nil
                }

                let startOfToday = Calendar.current.startOfDay(for: Date())
                let startDate = extractField("start_date").flatMap { iso.date(from: $0) ?? fallback($0) } ?? startOfToday
                let endDate   = extractField("end_date").flatMap { iso.date(from: $0) ?? fallback($0) }
                             ?? startDate.addingTimeInterval(7 * 24 * 3600)

                // Optionally filter by calendar name
                let calendarName = extractField("calendar")
                let allCalendars = store.calendars(for: .event)
                let calendars: [EKCalendar]? = calendarName.flatMap { name in
                    let matches = allCalendars.filter {
                        $0.title.lowercased().contains(name.lowercased())
                    }
                    return matches.isEmpty ? nil : matches
                }

                let predicate = store.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
                let events = store.events(matching: predicate)
                    .sorted { $0.startDate < $1.startDate }

                let df = DateFormatter()
                df.dateStyle = .medium
                df.timeStyle = .short

                var eventList = ""
                for e in events.prefix(50) {
                    let start = df.string(from: e.startDate)
                    let end   = df.string(from: e.endDate)
                    var entry = "• \(e.title ?? "(no title)") — \(start) to \(end)"
                    if let loc = e.location, !loc.isEmpty { entry += " @ \(loc)" }
                    if let cal = e.calendar { entry += " [\(cal.title)]" }
                    if let notes = e.notes, !notes.isEmpty { entry += "\n  Notes: \(notes)" }
                    eventList += entry + "\n"
                }

                if eventList.isEmpty {
                    let startStr = df.string(from: startDate)
                    let endStr   = df.string(from: endDate)
                    eventList = "No events found between \(startStr) and \(endStr)."
                }

                continuation.resume(returning:
                    "<|tool_response>response:list_calendar_events{result:<|\"|>\(eventList.trimmingCharacters(in: .whitespacesAndNewlines))<|\"|>}<tool_response|>"
                )
            }
        }
    }

    // MARK: - Read Reminders

    private nonisolated static func performListReminders(
        _ rawOutput: String,
        store: EKEventStore
    ) async -> String {
        func extractField(_ field: String) -> String? {
            let patterns = ["\(field):<\\|\"\\|>(.*?)<\\|\"\\|>", "\(field):\"(.*?)\""]
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern),
                      let match = regex.firstMatch(in: rawOutput, range: NSRange(rawOutput.startIndex..., in: rawOutput)),
                      let range = Range(match.range(at: 1), in: rawOutput) else { continue }
                return String(rawOutput[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }

        let listName = extractField("list")
        let includeCompleted = extractField("include_completed")?.lowercased() == "true"

        return await withCheckedContinuation { continuation in
            let requestAccess: (@escaping (Bool, Error?) -> Void) -> Void
            if #available(macOS 14.0, *) {
                requestAccess = { store.requestFullAccessToReminders(completion: $0) }
            } else {
                requestAccess = { store.requestAccess(to: .reminder, completion: $0) }
            }
            requestAccess { granted, error in
                guard granted else {
                    continuation.resume(returning:
                        "<|tool_response>response:list_reminders{error:<|\"|>Reminders access denied<|\"|>}<tool_response|>"
                    )
                    return
                }

                let allLists = store.calendars(for: .reminder)
                let targetLists: [EKCalendar] = {
                    guard let name = listName, !name.isEmpty else { return allLists }
                    let matches = allLists.filter {
                        $0.title.lowercased().contains(name.lowercased())
                    }
                    return matches.isEmpty ? allLists : matches
                }()

                let predicate = includeCompleted
                    ? store.predicateForReminders(in: targetLists)
                    : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: targetLists)

                store.fetchReminders(matching: predicate) { reminders in
                    let sorted = (reminders ?? []).sorted {
                        let a = $0.dueDateComponents?.date ?? Date.distantFuture
                        let b = $1.dueDateComponents?.date ?? Date.distantFuture
                        return a < b
                    }

                    let df = DateFormatter()
                    df.dateStyle = .medium
                    df.timeStyle = .short

                    var result = ""
                    for r in sorted.prefix(100) {
                        var entry = "• \(r.title ?? "(no title)")"
                        if let comps = r.dueDateComponents, let date = comps.date {
                            entry += " — due \(df.string(from: date))"
                        }
                        if let cal = r.calendar { entry += " [\(cal.title)]" }
                        if r.isCompleted { entry += " ✓" }
                        if let notes = r.notes, !notes.isEmpty { entry += "\n  Notes: \(notes)" }
                        result += entry + "\n"
                    }

                    if result.isEmpty {
                        result = listName.map { "No reminders found in '\($0)'." } ?? "No reminders found."
                    }

                    continuation.resume(returning:
                        "<|tool_response>response:list_reminders{result:<|\"|>\(result.trimmingCharacters(in: .whitespacesAndNewlines))<|\"|>}<tool_response|>"
                    )
                }
            }
        }
    }

    // MARK: - Python Runner

    private nonisolated static func performRunPython(_ rawOutput: String) async -> String {
        // Extract the code field — it may span multiple lines
        guard let code = extractPythonCode(from: rawOutput), !code.isEmpty else {
            return "<|tool_response>response:run_python{error:<|\"|>Could not extract Python code from tool call<|\"|>}<tool_response|>"
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Write to a temp file
                let tmpDir = FileManager.default.temporaryDirectory
                let scriptURL = tmpDir.appendingPathComponent("pendragon_\(UUID().uuidString).py")
                do {
                    try code.write(to: scriptURL, atomically: true, encoding: .utf8)
                } catch {
                    continuation.resume(returning:
                        "<|tool_response>response:run_python{error:<|\"|>Failed to write script: \(error.localizedDescription)<|\"|>}<tool_response|>"
                    )
                    return
                }
                defer { try? FileManager.default.removeItem(at: scriptURL) }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["python3", scriptURL.path]

                // Inherit PATH so pip-installed packages are visible
                var env = ProcessInfo.processInfo.environment
                env["PYTHONUNBUFFERED"] = "1"
                process.environment = env

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError  = stderrPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning:
                        "<|tool_response>response:run_python{error:<|\"|>Could not launch python3: \(error.localizedDescription)<|\"|>}<tool_response|>"
                    )
                    return
                }

                // Timeout: kill after 15 s
                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: killer)

                process.waitUntilExit()
                killer.cancel()

                let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

                var output = stdout
                if !stderr.isEmpty { output += (output.isEmpty ? "" : "\n") + "[stderr]\n" + stderr }
                if output.isEmpty  { output = "(no output)" }

                // Truncate to ~4000 chars to keep context reasonable
                let maxLen = 4000
                if output.count > maxLen {
                    output = String(output.prefix(maxLen)) + "\n… (truncated)"
                }

                let exitCode = process.terminationStatus
                let status = exitCode == 0 ? "exit 0" : "exit \(exitCode)"
                continuation.resume(returning:
                    "<|tool_response>response:run_python{\(status):<|\"|>\(output)<|\"|>}<tool_response|>"
                )
            }
        }
    }

    private nonisolated static func extractPythonCode(from rawOutput: String) -> String? {
        // The model may put the code in various ways inside the tool call
        // Try the standard token format first: code:<|"|>...<|"|>
        let tokenPattern = #"code:<\|"\|>([\s\S]*?)<\|"\|>"#
        if let regex = try? NSRegularExpression(pattern: tokenPattern),
           let match = regex.firstMatch(in: rawOutput, range: NSRange(rawOutput.startIndex..., in: rawOutput)),
           let range = Range(match.range(at: 1), in: rawOutput) {
            return String(rawOutput[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Fallback: code:"..." (JSON-style, possibly with escaped newlines)
        let jsonPattern = #"code:\s*"((?:[^"\\]|\\.)*)""#
        if let regex = try? NSRegularExpression(pattern: jsonPattern, options: [.dotMatchesLineSeparators]),
           let match = regex.firstMatch(in: rawOutput, range: NSRange(rawOutput.startIndex..., in: rawOutput)),
           let range = Range(match.range(at: 1), in: rawOutput) {
            return String(rawOutput[range])
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\t", with: "\t")
                .replacingOccurrences(of: "\\\"", with: "\"")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Last resort: everything after "code:" to end of tool call block
        if let range = rawOutput.range(of: "code:") {
            var rest = String(rawOutput[range.upperBound...])
            // strip leading/trailing token markers
            rest = rest.replacingOccurrences(of: "<|\"|>", with: "")
            rest = rest.replacingOccurrences(of: "}", with: "")
            return rest.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    nonisolated static func extractSearchQuery(from rawOutput: String) -> String? {
        // Try multiple patterns the model might use (official format first)
        let patterns = [
            #"call:web_search\s*\{\s*query\s*:\s*<\|"\|>(.*?)<\|"\|>"#,
            #"call:web_search\s*\{query:<\|"\|>(.*?)<\|"\|>"#,
            #"call:web_search\s*\{query:\s*"(.*?)""#,
            #"call:web_search\s*\{query:\s*'(.*?)'"#,
            #"call:web_search\s*\{(.*?)\}"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
               let match = regex.firstMatch(in: rawOutput, range: NSRange(rawOutput.startIndex..., in: rawOutput)),
               let range = Range(match.range(at: 1), in: rawOutput) {
                var query = String(rawOutput[range])
                // Clean up any remaining token artifacts
                query = query.replacingOccurrences(of: "<|\"|>", with: "")
                query = query.trimmingCharacters(in: .whitespacesAndNewlines)
                if !query.isEmpty {
                    return query
                }
            }
        }
        return nil
    }

    private nonisolated static func formatSearchResponse(query: String, results: [SearchResult]) -> String {
        var response = "<|tool_response>response:web_search{"
        response += "query:<|\"|>\(query)<|\"|>,"
        response += "results:["
        for (i, r) in results.prefix(5).enumerated() {
            if i > 0 { response += "," }
            let snippet = String(r.snippet.prefix(200))
            response += "{title:<|\"|>\(r.title)<|\"|>,url:<|\"|>\(r.url)<|\"|>,snippet:<|\"|>\(snippet)<|\"|>}"
        }
        response += "]}<tool_response|>"
        return response
    }

    private nonisolated static func extractFetchUrl(from rawOutput: String) -> String? {
        let patterns = [
            #"call:fetch_url\s*\{\s*url\s*:\s*<\|"\|>(.*?)<\|"\|>"#,
            #"call:fetch_url\s*\{url:<\|"\|>(.*?)<\|"\|>"#,
            #"call:fetch_url\s*\{url:\s*"(.*?)""#,
            #"call:fetch_url\s*\{(.*?)\}"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
               let match = regex.firstMatch(in: rawOutput, range: NSRange(rawOutput.startIndex..., in: rawOutput)),
               let range = Range(match.range(at: 1), in: rawOutput) {
                var url = String(rawOutput[range])
                url = url.replacingOccurrences(of: "<|\"|>", with: "")
                url = url.trimmingCharacters(in: .whitespacesAndNewlines)
                if !url.isEmpty { return url }
            }
        }
        return nil
    }

    private nonisolated static func fetchPageText(urlString: String) async -> String {
        var urlStr = urlString
        if !urlStr.hasPrefix("http://") && !urlStr.hasPrefix("https://") {
            urlStr = "https://" + urlStr
        }
        guard let url = URL(string: urlStr) else { return "[Error: Invalid URL]" }

        do {
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
                return "[Error: HTTP \(httpResponse.statusCode)]"
            }

            // Check if the response is a PDF (by content type or URL extension)
            let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
            if contentType.contains("application/pdf") || url.pathExtension.lowercased() == "pdf" {
                return Self.extractPDFText(from: data)
            }

            guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
                return "[Error: Could not decode page content]"
            }

            return Self.htmlToPlainText(html)
        } catch {
            return "[Error: \(error.localizedDescription)]"
        }
    }

    private nonisolated static func extractPDFText(from data: Data) -> String {
        guard let document = PDFDocument(data: data) else {
            return "[Error: Could not parse PDF]"
        }
        var text = ""
        let pageCount = min(document.pageCount, 50)
        for i in 0..<pageCount {
            if let page = document.page(at: i), let pageText = page.string {
                text += pageText + "\n"
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return "[PDF contains no extractable text — it may be scanned/image-based]"
        }
        if text.count > 6000 {
            text = String(text.prefix(6000)) + "\n[... truncated, \(document.pageCount) pages total]"
        }
        return text
    }

    private nonisolated static func htmlToPlainText(_ html: String) -> String {
        var text = html

        // Remove script and style blocks entirely
        let blockPatterns = [
            #"<script[^>]*>[\s\S]*?</script>"#,
            #"<style[^>]*>[\s\S]*?</style>"#,
            #"<nav[^>]*>[\s\S]*?</nav>"#,
            #"<header[^>]*>[\s\S]*?</header>"#,
            #"<footer[^>]*>[\s\S]*?</footer>"#,
        ]
        for pattern in blockPatterns {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }

        // Replace block elements with newlines
        text = text.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"</?(p|div|h[1-6]|li|tr|blockquote|pre|article|section)[^>]*>"#, with: "\n", options: .regularExpression)

        // Strip remaining tags
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)

        // Decode common HTML entities
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&nbsp;", " "), ("&#x27;", "'"), ("&#x2F;", "/"),
        ]
        for (entity, char) in entities {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        // Numeric entities
        text = text.replacingOccurrences(of: #"&#(\d+);"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"&#x[\da-fA-F]+;"#, with: "", options: .regularExpression)

        // Collapse whitespace
        text = text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Truncate to ~4000 chars to fit in context
        if text.count > 4000 {
            text = String(text.prefix(4000)) + "\n[... truncated]"
        }

        return text
    }

    private nonisolated static func formatFetchResponse(url: String, content: String) -> String {
        return "<|tool_response>response:fetch_url{url:<|\"|>\(url)<|\"|>,content:<|\"|>\(content)<|\"|>}<tool_response|>"
    }

    private nonisolated static func stripToolTokens(_ text: String) -> String {
        var result = text
        // Remove tool call/response markup
        let patterns = [
            #"<\|tool_call>.*?<tool_call\|>"#,
            #"<\|tool_response>.*?<tool_response\|>"#,
            #"<\|tool_call>"#,
            #"<tool_call\|>"#,
            #"<\|tool_response>"#,
            #"<tool_response\|>"#,
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return result
    }

    private nonisolated static func stripChannelTokens(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "<|channel>thought", with: "")
        result = result.replacingOccurrences(of: "<channel|>", with: "")
        result = result.replacingOccurrences(of: "<|channel>", with: "")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Hide tool-call syntax while it streams: the model emits raw
    /// `<|tool_call>…` markers that would otherwise flash in the bubble until
    /// the final answer replaces them. Cut the snapshot at the first marker,
    /// and also trim a partially-streamed marker at the tail (e.g. "…<|too").
    nonisolated static func hideStreamingToolSyntax(_ text: String) -> String {
        var out = text
        for marker in ["<|tool_call", "<|tool_response"] {
            if let r = out.range(of: marker) {
                out = String(out[..<r.lowerBound])
            }
        }
        // A marker may be mid-stream at the tail — trim any suffix that is a
        // prefix (length ≥ 2) of a marker so no fragment ever shows.
        for marker in ["<|tool_call", "<|tool_response"] {
            for len in stride(from: marker.count - 1, through: 2, by: -1) {
                if out.hasSuffix(String(marker.prefix(len))) {
                    out = String(out.dropLast(len))
                    break
                }
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Remove a complete thinking block (<|channel>thought\n…<channel|>) from stored text.
    /// Per Gemma 4 model card, historical assistant turns must not contain thinking content.
    /// This handles the full block, partial open/close remnants, and bare channel tokens.
    nonisolated static func stripThinkingBlocks(_ text: String) -> String {
        var result = text
        // Full block: <|channel>thought\n...<channel|>  (may span multiple lines)
        if let regex = try? NSRegularExpression(pattern: #"<\|channel>thought[\s\S]*?<channel\|>"#) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }
        // Anything that remains before a bare <channel|> end-marker
        if let range = result.range(of: "<channel|>") {
            result = String(result[range.upperBound...])
        }
        // Loose opening tokens
        result = result.replacingOccurrences(of: "<|channel>thought", with: "")
        result = result.replacingOccurrences(of: "<|channel>", with: "")
        result = result.replacingOccurrences(of: "<channel|>", with: "")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
