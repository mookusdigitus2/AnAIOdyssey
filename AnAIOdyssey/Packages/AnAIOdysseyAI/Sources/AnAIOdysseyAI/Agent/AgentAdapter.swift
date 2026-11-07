// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// Metadata describing a registered AI agent adapter.
public struct AgentAttributes: Sendable, Hashable, Identifiable {
    public let id: String
    public let displayName: String
    public let vendor: String
    public let tags: [String]
    public let capabilities: [String]
    public let isSwitchable: Bool

    public init(
        id: String,
        displayName: String,
        vendor: String,
        tags: [String],
        capabilities: [String] = [],
        isSwitchable: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.vendor = vendor
        self.tags = tags
        self.capabilities = capabilities
        self.isSwitchable = isSwitchable
    }
}

/// Working context passed into an agent (inline and/or file-backed).
public struct AgentWorkContext: Sendable {
    public let inlineText: String?
    public let fileText: String?
    public let metadata: [String: String]

    public init(inlineText: String? = nil, fileText: String? = nil, metadata: [String: String] = [:]) {
        self.inlineText = inlineText
        self.fileText = fileText
        self.metadata = metadata
    }

    /// Combined context body for prompting.
    public var combinedText: String? {
        let parts = [inlineText, fileText].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n\n---\n\n")
    }

    public static let empty = AgentWorkContext()
}

/// Prompt/assignment bundle supporting all four init modes (prompt only, context only, both, neither).
public struct AgentAssignment: Sendable {
    public let prompt: String?
    public let context: AgentWorkContext?

    public init(prompt: String? = nil, context: AgentWorkContext? = nil) {
        self.prompt = prompt
        self.context = context
    }

    public static let empty = AgentAssignment()
}

/// Result of running an agent against an assignment.
public struct AgentRunResult: Sendable {
    public let output: String
    public let metadata: [String: String]

    public init(output: String, metadata: [String: String] = [:]) {
        self.output = output
        self.metadata = metadata
    }
}

public enum AgentAdapterError: Error, LocalizedError {
    case notAvailable(String)
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notAvailable(let reason): return reason
        case .executionFailed(let reason): return reason
        }
    }
}

/// Consistent interface for all AI agents (local LLM, Cursor, remote vendors, …).
@MainActor
public protocol AgentAdapter: AnyObject {
    var attributes: AgentAttributes { get }
    var isAvailable: Bool { get }
    func run(assignment: AgentAssignment) async throws -> AgentRunResult
}
