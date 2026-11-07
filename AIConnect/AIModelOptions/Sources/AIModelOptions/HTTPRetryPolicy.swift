// SPDX-License-Identifier: MIT
import Foundation

/// Limited backoff for provider 429 / 5xx replies, honoring `Retry-After`.
public enum HTTPRetryPolicy {
    public static let retryableStatusCodes: Set<Int> = [429, 500, 502, 503, 504]
    public static let maxAttempts = 4

    public static func shouldRetry(statusCode: Int, attempt: Int, receivedStreamBytes: Bool) -> Bool {
        guard !receivedStreamBytes else { return false }
        guard attempt < maxAttempts else { return false }
        return retryableStatusCodes.contains(statusCode)
    }

    /// 429 codes that mean a plan or billing limit, not a brief rate limit. Retrying them only
    /// delays the error, so they fail on the first reply.
    public static let hardLimitErrorCodes: Set<String> = [
        "subscription_sharing_usage_limit_exceeded",
        "insufficient_quota",
    ]

    /// Same as above, but also looks at the error body so plan and billing limits are not retried.
    public static func shouldRetry(statusCode: Int, attempt: Int, receivedStreamBytes: Bool, body: Data) -> Bool {
        guard shouldRetry(statusCode: statusCode, attempt: attempt, receivedStreamBytes: receivedStreamBytes) else {
            return false
        }
        return !isHardLimit(body: body)
    }

    public static func isHardLimit(body: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return false }
        let error = (object["error"] as? [String: Any])
            ?? ((object["response"] as? [String: Any])?["error"] as? [String: Any])
        let values = [error?["code"], error?["type"]].compactMap { $0 as? String }
        return values.contains { hardLimitErrorCodes.contains($0) }
    }

    /// Seconds to wait before the next try. `Retry-After` may be a delay or an HTTP date;
    /// `retry-after-ms` is milliseconds.
    public static func delaySeconds(
        attempt: Int,
        retryAfter: String? = nil,
        retryAfterMilliseconds: String? = nil,
        now: Date = Date()
    ) -> TimeInterval {
        if let milliseconds = parsePositiveDouble(retryAfterMilliseconds) {
            return milliseconds / 1000
        }
        if let header = retryAfter?.trimmingCharacters(in: .whitespacesAndNewlines), !header.isEmpty {
            if let seconds = parsePositiveDouble(header) {
                return seconds
            }
            if let date = parseHTTPDate(header) {
                return max(date.timeIntervalSince(now), 0)
            }
        }
        return min(pow(2, Double(attempt - 1)) * 0.5, 8)
    }

    private static func parsePositiveDouble(_ raw: String?) -> Double? {
        guard let raw, let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)), value >= 0 else {
            return nil
        }
        return value
    }

    private static func parseHTTPDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: raw)
    }
}

/// Prompt / completion token counts from a Chat Completions or Responses payload.
public struct TokenUsage: Equatable, Sendable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var totalTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, totalTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
    }

    public var isEmpty: Bool {
        inputTokens == nil && outputTokens == nil && totalTokens == nil
    }

    public static func parse(from object: [String: Any]) -> TokenUsage? {
        let usage = (object["usage"] as? [String: Any])
            ?? ((object["response"] as? [String: Any])?["usage"] as? [String: Any])
        guard let usage else { return nil }
        let input = intValue(usage["prompt_tokens"]) ?? intValue(usage["input_tokens"])
        let output = intValue(usage["completion_tokens"]) ?? intValue(usage["output_tokens"])
        let total = intValue(usage["total_tokens"])
        let parsed = TokenUsage(inputTokens: input, outputTokens: output, totalTokens: total)
        return parsed.isEmpty ? nil : parsed
    }

    public static func parse(json: String) -> TokenUsage? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parse(from: object)
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? Double { return Int(value) }
        if let number = raw as? NSNumber { return number.intValue }
        return nil
    }
}
