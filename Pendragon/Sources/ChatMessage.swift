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
    let timestamp: Date

    enum Role {
        case user
        case assistant
    }

    init(id: UUID = UUID(), role: Role, content: String, images: [NSImage] = [], imageDatas: [Data] = [], hasAudio: Bool = false, audioDuration: TimeInterval? = nil, pdfName: String? = nil, pdfText: String? = nil, pdfThumbnail: NSImage? = nil, usedWebSearch: Bool = false, fetchedURL: String? = nil, sourceURLs: [(title: String, url: String)] = [], hasVisualization: Bool = false, visualizationCode: String? = nil) {
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
        self.timestamp = Date()
    }
}
