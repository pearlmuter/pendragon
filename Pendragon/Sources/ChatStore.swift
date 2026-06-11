import Foundation
import AppKit

/// Persistent storage for chat threads
struct ChatThread: Identifiable, Codable {
    let id: UUID
    var title: String
    var messages: [StoredMessage]
    var createdAt: Date
    var updatedAt: Date
    var conversationSummary: String?

    struct StoredMessage: Identifiable, Codable {
        let id: UUID
        let role: String // "user" or "assistant"
        var content: String
        // Multi-image: imageDatas replaces the old single imageData field.
        // imageData is kept for reading legacy persisted data.
        var imageDatas: [Data]?
        var imageData: Data?       // legacy – read-only migration path
        var hasAudio: Bool
        var audioDuration: TimeInterval?
        var pdfName: String?
        var pdfText: String?
        var usedWebSearch: Bool?
        var fetchedURL: String?
        var sourceURLs: [SourceLink]?
        var visualizationCode: String?
        let timestamp: Date

        struct SourceLink: Codable {
            let title: String
            let url: String
        }
    }

    init(id: UUID = UUID(), title: String = "New Chat", messages: [StoredMessage] = [], createdAt: Date = Date(), updatedAt: Date = Date(), conversationSummary: String? = nil) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.conversationSummary = conversationSummary
    }
}

@MainActor
class ChatStore: ObservableObject {
    @Published var threads: [ChatThread] = []

    /// IDs of pinned threads — stored in UserDefaults so no Codable changes needed
    private(set) var pinnedIds: Set<UUID> = []
    private static let pinnedKey = "Pendragon.pinnedThreadIds"

    private let saveDirectory: URL
    private static let expiryInterval: TimeInterval = 7 * 24 * 3600

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        saveDirectory = appSupport.appendingPathComponent("Pendragon/Chats", isDirectory: true)
        try? FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
        loadPinnedIds()
        loadThreads()
    }

    // MARK: - Pin / Unpin

    func togglePin(_ thread: ChatThread) {
        if pinnedIds.contains(thread.id) {
            pinnedIds.remove(thread.id)
        } else {
            pinnedIds.insert(thread.id)
        }
        savePinnedIds()
        sortThreads()
    }

    func isPinned(_ thread: ChatThread) -> Bool {
        pinnedIds.contains(thread.id)
    }

    // MARK: - Convert between ChatMessage and StoredMessage

    static func toStored(_ msg: ChatMessage) -> ChatThread.StoredMessage {
        ChatThread.StoredMessage(
            id: msg.id,
            role: msg.role == .user ? "user" : "assistant",
            content: msg.content,
            imageDatas: nil,  // raw bytes never persisted — too large; display uses NSImage rebuilt at send time
            imageData: nil,   // no longer written; legacy read path only
            hasAudio: msg.hasAudio,
            audioDuration: msg.audioDuration,
            pdfName: msg.pdfName,
            pdfText: msg.pdfText,
            usedWebSearch: msg.usedWebSearch ? true : nil,
            fetchedURL: msg.fetchedURL,
            sourceURLs: msg.sourceURLs.isEmpty ? nil : msg.sourceURLs.map { ChatThread.StoredMessage.SourceLink(title: $0.title, url: $0.url) },
            visualizationCode: msg.visualizationCode,
            timestamp: msg.timestamp
        )
    }

    static func fromStored(_ stored: ChatThread.StoredMessage) -> ChatMessage {
        let role: ChatMessage.Role = stored.role == "user" ? .user : .assistant
        // Raw image bytes are no longer persisted — historical messages show no thumbnail.
        // NSImage display thumbnails were only valid during the originating session.
        return ChatMessage(
            id: stored.id,   // stable UUID — audio cache survives conversation switches
            role: role,
            content: stored.content,
            images: [],
            imageDatas: [],
            hasAudio: stored.hasAudio,
            audioDuration: stored.audioDuration,
            pdfName: stored.pdfName,
            pdfText: stored.pdfText,
            usedWebSearch: stored.usedWebSearch ?? false,
            fetchedURL: stored.fetchedURL,
            sourceURLs: stored.sourceURLs?.map { (title: $0.title, url: $0.url) } ?? [],
            hasVisualization: stored.visualizationCode != nil,
            visualizationCode: stored.visualizationCode
        )
    }

    // MARK: - Title generation

    static func generateTitle(from messages: [ChatMessage]) -> String {
        guard let first = messages.first(where: { $0.role == .user && !$0.content.isEmpty }) else {
            if messages.contains(where: { $0.hasAudio }) { return "Voice Chat" }
            if messages.contains(where: { !$0.images.isEmpty }) { return "Image Chat" }
            return "New Chat"
        }
        let text = first.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count <= 40 { return text }
        let truncated = String(text.prefix(37))
        if let space = truncated.lastIndex(of: " ") {
            return String(truncated[..<space]) + "..."
        }
        return truncated + "..."
    }

    // MARK: - Persistence

    private func filePath(for id: UUID) -> URL {
        saveDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    func saveThread(_ thread: ChatThread) {
        if let idx = threads.firstIndex(where: { $0.id == thread.id }) {
            threads[idx] = thread
        } else {
            threads.insert(thread, at: 0)
        }
        sortThreads()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(thread) {
            try? data.write(to: filePath(for: thread.id), options: .atomic)
        }
    }

    func deleteThread(_ thread: ChatThread) {
        pinnedIds.remove(thread.id)
        savePinnedIds()
        threads = threads.filter { $0.id != thread.id }   // assignment fires @Published
        try? FileManager.default.removeItem(at: filePath(for: thread.id))
    }

    private func loadThreads() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let files = try? FileManager.default.contentsOfDirectory(at: saveDirectory, includingPropertiesForKeys: nil) else { return }

        var loaded: [ChatThread] = []
        let cutoff = Date().addingTimeInterval(-Self.expiryInterval)

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let thread = try? decoder.decode(ChatThread.self, from: data) else { continue }

            // Auto-delete unpinned threads older than one week
            if !pinnedIds.contains(thread.id) && thread.updatedAt < cutoff {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            loaded.append(thread)
        }

        threads = loaded
        sortThreads()
    }

    // MARK: - Sorting

    /// Pinned threads first (sorted by most-recently-updated so they always reflect activity).
    /// Unpinned threads keep their insertion position — sorted by createdAt so a chat
    /// doesn't jump to the top just because a new message was added to it.
    private func sortThreads() {
        threads = threads.sorted { a, b in
            let aPin = pinnedIds.contains(a.id)
            let bPin = pinnedIds.contains(b.id)
            if aPin != bPin { return aPin }
            if aPin { return a.updatedAt > b.updatedAt }
            return a.createdAt > b.createdAt
        }
    }

    // MARK: - Pin persistence

    private func loadPinnedIds() {
        guard let data = UserDefaults.standard.data(forKey: Self.pinnedKey),
              let ids = try? JSONDecoder().decode([UUID].self, from: data) else { return }
        pinnedIds = Set(ids)
    }

    private func savePinnedIds() {
        let arr = Array(pinnedIds)
        if let data = try? JSONEncoder().encode(arr) {
            UserDefaults.standard.set(data, forKey: Self.pinnedKey)
        }
    }
}
