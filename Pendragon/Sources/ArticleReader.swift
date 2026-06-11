import Foundation

// MARK: - Article

struct Article {
    let title: String
    let body: String
    let url: URL

    var wordCount: Int { body.split(separator: " ").count }
    var estimatedMinutes: Int { max(1, wordCount / 150) }  // ~150 wpm TTS
    var preview: String {
        let first = body.components(separatedBy: "\n\n").first ?? body
        return String(first.prefix(280))
    }
}

// MARK: - ArticleError

enum ArticleError: LocalizedError {
    case badURL
    case httpError(Int)
    case noContent

    var errorDescription: String? {
        switch self {
        case .badURL:          return "That doesn't look like a valid URL."
        case .httpError(let c): return "Server returned HTTP \(c)."
        case .noContent:       return "Could not find any article text on that page."
        }
    }
}

// MARK: - ArticleReader

struct ArticleReader {

    static func fetch(_ rawURL: String) async throws -> Article {
        var cleaned = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.hasPrefix("http://") && !cleaned.hasPrefix("https://") {
            cleaned = "https://" + cleaned
        }
        guard let url = URL(string: cleaned) else { throw ArticleError.badURL }

        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else { throw ArticleError.httpError(status) }

        let html = String(data: data, encoding: .utf8)
               ?? String(data: data, encoding: .isoLatin1)
               ?? ""
        return try extract(from: html, url: url)
    }

    // MARK: - Extraction

    static func extract(from html: String, url: URL) throws -> Article {
        let title = extractTitle(html)
        let body  = extractBody(html)
        if body.count < 100 { throw ArticleError.noContent }
        return Article(title: title, body: body, url: url)
    }

    // MARK: - Title

    private static func extractTitle(_ html: String) -> String {
        // og:title is cleanest (no " | Site" suffixes)
        let ogPatterns = [
            #"<meta[^>]+property="og:title"[^>]+content="([^"]+)""#,
            #"<meta[^>]+content="([^"]+)"[^>]+property="og:title""#,
        ]
        for p in ogPatterns {
            if let t = firstCapture(html, pattern: p, options: .caseInsensitive) {
                return decodeEntities(t).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // <title> with " | Site" stripped
        if let t = firstCapture(html, pattern: #"<title[^>]*>([^<]+)</title>"#, options: .caseInsensitive) {
            let clean = t.components(separatedBy: " | ").first
                      ?? t.components(separatedBy: " - ").first
                      ?? t
            return decodeEntities(clean).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "Article"
    }

    // MARK: - Body

    private static func extractBody(_ html: String) -> String {
        var work = removeBlocks(html, tags: [
            "script", "style", "noscript", "nav", "header", "footer",
            "aside", "form", "figure", "figcaption", "iframe",
            "button", "select", "textarea", "dialog",
        ])

        // Try semantic content blocks in priority order
        let semanticPatterns: [(String, NSRegularExpression.Options)] = [
            (#"<article[^>]*>([\s\S]+)</article>"#, .caseInsensitive),
            (#"<main[^>]*>([\s\S]+)</main>"#,      .caseInsensitive),
        ]
        for (pattern, opts) in semanticPatterns {
            if let block = firstCapture(work, pattern: pattern, options: opts) {
                let text = paragraphs(from: block)
                if text.count > 300 { return text }
            }
        }

        // Fallback: all <p> tags from cleaned body (works for most static sites)
        return paragraphs(from: work)
    }

    private static func paragraphs(from html: String) -> String {
        guard let re = try? NSRegularExpression(
            pattern: #"<p[^>]*>([\s\S]*?)</p>"#, options: .caseInsensitive) else { return "" }

        var result: [String] = []
        let range = NSRange(html.startIndex..., in: html)
        re.enumerateMatches(in: html, range: range) { m, _, _ in
            guard let m, let r = Range(m.range(at: 1), in: html) else { return }
            let text = decodeEntities(stripTags(String(html[r])))
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count > 40 { result.append(text) }
        }
        return result.joined(separator: "\n\n")
    }

    // MARK: - Helpers

    private static func removeBlocks(_ html: String, tags: [String]) -> String {
        var s = html
        for tag in tags {
            s = s.replacingOccurrences(
                of: "<\(tag)(?:\\s[^>]*)?>(?:[\\s\\S]*?)</\(tag)>",
                with: "", options: [.regularExpression, .caseInsensitive])
        }
        return s
    }

    static func stripTags(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    private static func decodeEntities(_ text: String) -> String {
        var s = text
        let map: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"),
            ("&nbsp;", " "), ("&mdash;", "—"), ("&ndash;", "–"),
            ("&lsquo;", "\u{2018}"), ("&rsquo;", "\u{2019}"),
            ("&ldquo;", "\u{201C}"), ("&rdquo;", "\u{201D}"),
        ]
        for (e, r) in map { s = s.replacingOccurrences(of: e, with: r) }
        // Remove remaining numeric entities
        s = s.replacingOccurrences(of: #"&#\d+;"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"&[a-z]+;"#, with: "", options: .regularExpression)
        return s
    }

    private static func firstCapture(_ html: String, pattern: String,
                                      options: NSRegularExpression.Options = []) -> String? {
        guard let re   = try? NSRegularExpression(pattern: pattern, options: options),
              let match = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[range])
    }
}
