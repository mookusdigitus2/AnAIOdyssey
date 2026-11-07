// SPDX-License-Identifier: MIT
import Foundation

/// Milestones on the path from a user message to spoken audio.
public enum VoiceLatencyMark: String, CaseIterable, Sendable, Equatable {
    case requestSent
    case firstLLMToken
    case firstTTSRequest
    case firstAudioByte
    case playbackStart
}

/// Lightweight timing for one spoken turn. First and later turns are tagged
/// separately so a cold start can be compared with a warm follow-up.
public struct VoiceLatencyTrace: Equatable, Sendable {
    public var turnKind: VoiceTurnKind
    public var turnIndex: Int
    public var marks: [VoiceLatencyMark: TimeInterval]

    public init(
        turnKind: VoiceTurnKind,
        turnIndex: Int = 0,
        marks: [VoiceLatencyMark: TimeInterval] = [:]
    ) {
        self.turnKind = turnKind
        self.turnIndex = turnIndex
        self.marks = marks
    }

    public mutating func mark(_ mark: VoiceLatencyMark, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if marks[mark] == nil {
            marks[mark] = time
        }
    }

    public func time(for mark: VoiceLatencyMark) -> TimeInterval? {
        marks[mark]
    }

    public func seconds(from start: VoiceLatencyMark, to end: VoiceLatencyMark) -> TimeInterval? {
        guard let startTime = marks[start], let endTime = marks[end] else { return nil }
        return endTime - startTime
    }

    public func milliseconds(from start: VoiceLatencyMark, to end: VoiceLatencyMark) -> Int? {
        guard let interval = seconds(from: start, to: end) else { return nil }
        return Int((interval * 1000).rounded())
    }

    /// User-perceived spoken-reply latency: send → first audio playing.
    public func timeToFirstAudioMilliseconds() -> Int? {
        milliseconds(from: .requestSent, to: .playbackStart)
    }

    public func summaryLine() -> String {
        func ms(_ start: VoiceLatencyMark, _ end: VoiceLatencyMark) -> String {
            milliseconds(from: start, to: end).map { "\($0)ms" } ?? "—"
        }
        let label = turnKind == .first ? "first" : "later"
        return [
            "Voice latency (\(label) turn #\(turnIndex + 1)):",
            "request→play \(ms(.requestSent, .playbackStart))",
            "(llm \(ms(.requestSent, .firstLLMToken)),",
            "chunk \(ms(.firstLLMToken, .firstTTSRequest)),",
            "tts \(ms(.firstTTSRequest, .firstAudioByte)),",
            "play \(ms(.firstAudioByte, .playbackStart)))",
        ].joined(separator: " ")
    }
}
