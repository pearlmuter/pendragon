import Foundation

struct SearchResult {
    let title: String
    let url: String
    let snippet: String
}

actor WebSearchService {
    func search(query: String, maxResults: Int = 5) async -> [SearchResult] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encoded)") else {
            return []
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let html = String(data: data, encoding: .utf8) else { return [] }
            return parseResults(html: html, max: maxResults)
        } catch {
            print("Search error: \(error)")
            return []
        }
    }

    private func parseResults(html: String, max: Int) -> [SearchResult] {
        var results: [SearchResult] = []

        // DuckDuckGo HTML results are in <a class="result__a"> with <a class="result__snippet">
        let resultPattern = #"class="result__a"[^>]*href="([^"]*)"[^>]*>([^<]*)</a>.*?class="result__snippet"[^>]*>(.*?)</a>"#

        guard let regex = try? NSRegularExpression(pattern: resultPattern, options: [.dotMatchesLineSeparators]) else {
            return extractFallback(html: html, max: max)
        }

        let range = NSRange(html.startIndex..., in: html)
        let matches = regex.matches(in: html, range: range)

        for match in matches.prefix(max) {
            let urlRange = Range(match.range(at: 1), in: html)
            let titleRange = Range(match.range(at: 2), in: html)
            let snippetRange = Range(match.range(at: 3), in: html)

            let rawUrl = urlRange.map { String(html[$0]) } ?? ""
            let title = titleRange.map { String(html[$0]) } ?? ""
            let snippet = snippetRange.map { stripHtml(String(html[$0])) } ?? ""

            let cleanUrl = cleanDDGUrl(rawUrl)

            if !title.isEmpty {
                results.append(SearchResult(title: title, url: cleanUrl, snippet: snippet))
            }
        }

        if results.isEmpty {
            return extractFallback(html: html, max: max)
        }

        return results
    }

    private func extractFallback(html: String, max: Int) -> [SearchResult] {
        var results: [SearchResult] = []

        // Simpler pattern: find result links and nearby text
        let linkPattern = #"class="result__a"[^>]*href="([^"]*)"[^>]*>([\s\S]*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: linkPattern, options: []) else { return [] }

        let range = NSRange(html.startIndex..., in: html)
        let matches = regex.matches(in: html, range: range)

        for match in matches.prefix(max) {
            let urlRange = Range(match.range(at: 1), in: html)
            let titleRange = Range(match.range(at: 2), in: html)

            let rawUrl = urlRange.map { String(html[$0]) } ?? ""
            let title = titleRange.map { stripHtml(String(html[$0])) } ?? ""
            let cleanUrl = cleanDDGUrl(rawUrl)

            if !title.isEmpty && !cleanUrl.isEmpty {
                results.append(SearchResult(title: title, url: cleanUrl, snippet: ""))
            }
        }

        return results
    }

    private func cleanDDGUrl(_ rawUrl: String) -> String {
        // DuckDuckGo wraps URLs: //duckduckgo.com/l/?uddg=https%3A%2F%2F...
        if rawUrl.contains("uddg="),
           let components = URLComponents(string: rawUrl.hasPrefix("//") ? "https:" + rawUrl : rawUrl),
           let uddg = components.queryItems?.first(where: { $0.name == "uddg" })?.value {
            return uddg
        }
        if rawUrl.hasPrefix("//") {
            return "https:" + rawUrl
        }
        return rawUrl
    }

    private func stripHtml(_ html: String) -> String {
        var text = html
        // Remove HTML tags
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // Decode common entities
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#x27;", with: "'")
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
