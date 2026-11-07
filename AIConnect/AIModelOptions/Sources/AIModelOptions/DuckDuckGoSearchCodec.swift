// SPDX-License-Identifier: MIT
import Foundation

/// A quick-fact row from DuckDuckGo's Instant Answer API.
public struct DuckDuckGoInstantAnswer: Equatable, Sendable {
    public var heading: String
    public var text: String
    public var url: String
    public var source: String

    public init(heading: String, text: String, url: String, source: String) {
        self.heading = heading
        self.text = text
        self.url = url
        self.source = source
    }
}

/// Official DuckDuckGo Instant Answer helpers plus readable-page extraction.
///
/// Instant Answer (`api.duckduckgo.com`) returns abstracts and related topics
/// only — not a full web index. The unofficial HTML results page is not used.
public enum DuckDuckGoSearchCodec {
    public static let instantAnswerEndpoint = "https://api.duckduckgo.com/"
    public static let pageTextCap = 3_000
    public static let pageFetchCount = 3
    public static let pageFetchTimeout: TimeInterval = 8
    public static let pageFetchByteCap = 256_000

    /// User agent for Instant Answer and page fetches. The homepage comes from
    /// `AIProjectHomepage` so the host app can set it.
    public static var userAgent: String {
        "AnAIOdyssey/1.0 (+\(AIProjectHomepage.url); Instant Answer client)"
    }

    public static func instantAnswerURL(query: String) -> URL? {
        var components = URLComponents(string: instantAnswerEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "no_html", value: "1"),
            URLQueryItem(name: "skip_disambig", value: "1"),
            URLQueryItem(name: "no_redirect", value: "1"),
        ]
        return components?.url
    }

    public static func decodeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "<b>", with: "")
            .replacingOccurrences(of: "</b>", with: "")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func parseInstantAnswer(json data: Data) -> DuckDuckGoInstantAnswer? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let text = (object["AbstractText"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let url = (object["AbstractURL"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let heading = (object["Heading"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let source = (object["AbstractSource"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty {
            return DuckDuckGoInstantAnswer(
                heading: heading,
                text: text,
                url: url,
                source: source
            )
        }
        if let topics = object["RelatedTopics"] as? [[String: Any]] {
            for topic in topics {
                if let related = topic["Text"] as? String,
                   let firstURL = topic["FirstURL"] as? String,
                   !related.isEmpty {
                    return DuckDuckGoInstantAnswer(
                        heading: heading,
                        text: related,
                        url: firstURL,
                        source: source
                    )
                }
            }
        }
        return nil
    }

    /// Strips tags and scripts, then caps readable text for the model.
    public static func readableText(fromHTML html: String, maxCharacters: Int = pageTextCap) -> String {
        var text = html
        let stripBlocks = [
            #"<script[\s\S]*?</script>"#,
            #"<style[\s\S]*?</style>"#,
            #"<noscript[\s\S]*?</noscript>"#,
        ]
        for pattern in stripBlocks {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
            }
        }
        if let tags = try? NSRegularExpression(pattern: #"<[^>]+>"#) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = tags.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
        }
        text = decodeHTML(text)
        if let space = try? NSRegularExpression(pattern: #"\s+"#) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = space.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count <= maxCharacters {
            return text
        }
        let end = text.index(text.startIndex, offsetBy: maxCharacters)
        return String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
