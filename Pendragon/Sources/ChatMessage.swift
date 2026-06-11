import Foundation
import AppKit

struct ChatMessage: Identifiable {
    let id: UUID
    let role: Role
    var content: String
    var images: [NSImage]
    var imageDatas: [Data]
    var hasAudio: Bool
    var audioDuration: TimeInterval?
    var pdfName: String?
    var pdfText: String?
    var pdfThumbnail: NSImage?
    var usedWebSearch: Bool
    var fetchedURL: String?
    var sourceURLs: [(title: String, url: String)]
    var hasVisualization: Bool
    var visualizationCode: String?
    /// When set, TTS synthesizes this text instead of `content`.
    /// Used for web-article messages where the bubble shows the headline
    /// but the audio is the full article body.
    var ttsOverride: String?
    let timestamp: Date

    /// The text that should be synthesized for this message.
    var ttsContent: String { ttsOverride ?? content }

    enum Role {
        case user
        case assistant
    }

    init(id: UUID = UUID(), role: Role, content: String, images: [NSImage] = [], imageDatas: [Data] = [], hasAudio: Bool = false, audioDuration: TimeInterval? = nil, pdfName: String? = nil, pdfText: String? = nil, pdfThumbnail: NSImage? = nil, usedWebSearch: Bool = false, fetchedURL: String? = nil, sourceURLs: [(title: String, url: String)] = [], hasVisualization: Bool = false, visualizationCode: String? = nil, ttsOverride: String? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.images = images
        self.imageDatas = imageDatas
        self.hasAudio = hasAudio
        self.audioDuration = audioDuration
        self.pdfName = pdfName
        self.pdfText = pdfText
        self.pdfThumbnail = pdfThumbnail
        self.usedWebSearch = usedWebSearch
        self.fetchedURL = fetchedURL
        self.sourceURLs = sourceURLs
        self.hasVisualization = hasVisualization
        self.visualizationCode = visualizationCode
        self.ttsOverride = ttsOverride
        self.timestamp = Date()
    }
}
