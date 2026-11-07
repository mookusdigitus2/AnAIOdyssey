// SPDX-License-Identifier: MIT
import Foundation
import AIModelOptions

/// Whether a model can make native tool calls.
public enum ModelToolSupport: String, Codable, Sendable {
    case supported, unsupported, unknown
}

/// Tool support from the provider's own capability info, then a fallback table by model family.
public enum ModelToolSupportCatalog {
    /// What the model can do. Whether an app can drive the connection's protocol is a separate
    /// question (``ToolModelPolicy/protocolReason``).
    ///
    /// On LM Studio every chat model can call tools. `trained_for_tool_use: false` is the
    /// default prompt format, and a saved `false` from that misreading must not refuse the model.
    /// Embedding and decision rows are the ones that cannot.
    ///
    /// A server on this device or the local network that hasn't said it isn't LM Studio may be
    /// LM Studio (on any port), so its saved `false` alone never refuses a model there: the name
    /// table and the tool test decide.
    public static func support(modelID: String, connection: RemoteConnection?) -> ModelToolSupport {
        if connection?.servesLMStudioTools == true {
            if !ModelCapabilityCatalog.isChatModel(modelID) { return .unsupported }
            return .supported
        }
        if let reported = connection?.modelToolSupport?[modelID] {
            if reported { return .supported }
            if let connection, !OpenAICompatibleAPI.isPrivateNetworkHost(connection.trimmedBaseURL)
                || connection.currentLMStudioDetection == false { return .unsupported }
        }
        return fallback(modelID: modelID)
    }

    /// Families known to take (or refuse) tools when the provider doesn't say. Anything else is
    /// `.unknown`, which the one-time tool test settles.
    public static func fallback(modelID: String) -> ModelToolSupport {
        let leaf = ModelCapabilityCatalog.leafModelID(modelID)
        if !ModelCapabilityCatalog.isChatModel(leaf) { return .unsupported }
        if noToolPrefixes.contains(where: { leaf.hasPrefix($0) }) { return .unsupported }
        if toolPrefixes.contains(where: { leaf.hasPrefix($0) }) { return .supported }
        if let qwen = qwenVersion(leaf), qwen >= (2, 5) { return .supported }
        return .unknown
    }

    /// `qwen3.8-flash-next` -> (3, 8), `qwen2.5-coder` -> (2, 5), `qwen10` -> (10, 0).
    static func qwenVersion(_ leaf: String) -> (Int, Int)? {
        guard leaf.hasPrefix("qwen") else { return nil }
        let rest = leaf.dropFirst(4)
        let majorDigits = rest.prefix { $0.isASCII && $0.isNumber }
        guard let major = Int(majorDigits) else { return nil }
        var minor = 0
        let afterMajor = rest.dropFirst(majorDigits.count)
        if afterMajor.first == "." {
            minor = Int(afterMajor.dropFirst().prefix { $0.isASCII && $0.isNumber }) ?? 0
        }
        return (major, minor)
    }

    static let noToolPrefixes = ["o1-mini", "o1-preview", "gpt-3.5-turbo-instruct", "chatgpt-4o-latest", "grok-imagine", "deepseek-r1"]
    static let toolPrefixes = [
        "gpt-4o", "gpt-4.1", "gpt-4-turbo", "gpt-5", "gpt-6", "gpt-oss", "o1", "o3", "o4",
        "grok-", "gemini-", "claude-",
        "qwq", "llama-3.1", "llama-3.2", "llama-3.3", "llama-4", "llama3.1", "llama3.2", "llama3.3",
        "mistral", "mixtral", "codestral", "devstral", "magistral", "deepseek-v3", "deepseek-chat", "kimi-", "glm-4",
    ]
}

/// Result of the one-time tool test call, per model selection key
/// (`remote|<connection id>|<model id>`, so a deleted or recreated connection starts untested).
public final class ToolCallVerificationStore: @unchecked Sendable {
    private let defaults: UserDefaults
    /// Version 2. Results saved before it (key ``legacyKey``) are moved over once, passes only:
    /// failures from older builds' tests are tested again.
    private let key = "aiconnect.toolCallVerification.v2"
    private static let legacyKey = "aiconnect.toolCallVerification"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        migrateOnce()
    }

    private func migrateOnce() {
        guard let legacy = defaults.dictionary(forKey: Self.legacyKey) else { return }
        var all = (defaults.dictionary(forKey: key) as? [String: Bool]) ?? [:]
        for case let (selectionKey, true) in (legacy as? [String: Bool]) ?? [:] where all[selectionKey] == nil {
            all[selectionKey] = true
        }
        defaults.set(all, forKey: key)
        defaults.removeObject(forKey: Self.legacyKey)
    }

    /// True passed, false failed, nil never tested.
    public func result(for selectionKey: String) -> Bool? {
        (defaults.dictionary(forKey: key) as? [String: Bool])?[selectionKey]
    }

    public func record(passed: Bool, for selectionKey: String) {
        var all = (defaults.dictionary(forKey: key) as? [String: Bool]) ?? [:]
        all[selectionKey] = passed
        defaults.set(all, forKey: key)
    }

    /// Records a pass or fail. Nil is an inconclusive test (a timeout, a server error, an
    /// unreachable server), which is not saved, so the model stays untested. Returns whether
    /// anything was recorded.
    @discardableResult
    public func recordIfConclusive(passed: Bool?, for selectionKey: String) -> Bool {
        guard let passed else { return false }
        record(passed: passed, for: selectionKey)
        return true
    }

    /// Forgets a connection's saved failures, so its models count as untested; passes are kept.
    public func clearFailures(connectionID: String) {
        var all = (defaults.dictionary(forKey: key) as? [String: Bool]) ?? [:]
        all = all.filter { $0.value || !$0.key.hasPrefix("\(LLMBackendPreference.remote.rawValue)|\(connectionID)|") }
        defaults.set(all, forKey: key)
    }

    public func clear(connectionID: String) {
        var all = (defaults.dictionary(forKey: key) as? [String: Bool]) ?? [:]
        all = all.filter { !$0.key.hasPrefix("\(LLMBackendPreference.remote.rawValue)|\(connectionID)|") }
        defaults.set(all, forKey: key)
    }
}

/// Whether a model can be picked for an agent that calls tools.
public enum ToolModelAvailability: Equatable, Sendable {
    case ready
    /// Looks capable, but the one-time test call hasn't run yet.
    case needsTest
    /// The last test call failed. Still pickable: picking it (or Test Tool Calls) runs the test again.
    case failedTest
    case unavailable(String)

    public var isSelectable: Bool {
        if case .unavailable = self { return false }
        return true
    }

    /// Picking the model runs the one-time tool test before it's used.
    public var runsTestWhenPicked: Bool {
        self == .needsTest || self == .failedTest || self == .unavailable(ToolModelPolicy.noToolsReason)
    }

    /// Test Tool Calls is offered: for every model the app can drive, including one marked
    /// "Doesn't support tools", since a passing test overrides what the provider reported.
    /// Only a connection type the app can't use (or a missing connection) can't be tested.
    public var canRunToolTest: Bool {
        isSelectable || self == .unavailable(ToolModelPolicy.noToolsReason)
    }
}

public struct ModelChoiceGroup: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let choices: [ConfiguredModelChoice]
}

public enum ToolModelPolicy {
    public static let noToolsReason = "Doesn't support tools"
    public static let failedTestReason = "Failed the tool test"
    public static let protocolReason = "Connection type can't call tools here"
    public static let untestedLabel = "Untested"

    public static func availability(
        of choice: ConfiguredModelChoice,
        connection: RemoteConnection?,
        store: ToolCallVerificationStore,
        usableEncodings: Set<RemoteProtocolEncoding>
    ) -> ToolModelAvailability {
        switch choice.backend {
        case .appleFoundation, .auto:
            return .ready
        case .localMLX:
            return .unavailable(noToolsReason)
        case .remote:
            guard let connection else { return .unavailable("Connection missing") }
            if !usableEncodings.contains(connection.encoding) { return .unavailable(protocolReason) }
            // Only explicit evidence (the provider's own list, or a family known to refuse tools)
            // marks a model without tools; unknown models are untested and the test call decides.
            // A passed test beats that evidence.
            let verdict = store.result(for: choice.selectionKey)
            if verdict != true, ModelToolSupportCatalog.support(modelID: choice.id, connection: connection) == .unsupported {
                return .unavailable(noToolsReason)
            }
            switch verdict {
            case true?: return .ready
            case false?: return .failedTest
            case nil: return .needsTest
            }
        }
    }

    /// Remote models grouped by connection (in list order), then on-device models.
    public static func grouped(_ choices: [ConfiguredModelChoice]) -> [ModelChoiceGroup] {
        var order: [String] = []
        var titles: [String: String] = [:]
        var members: [String: [ConfiguredModelChoice]] = [:]
        var local: [ConfiguredModelChoice] = []
        for choice in choices {
            guard choice.backend == .remote, let id = choice.connectionID else { local.append(choice); continue }
            if members[id] == nil { order.append(id); titles[id] = choice.providerLabel }
            members[id, default: []].append(choice)
        }
        var groups = order.map { ModelChoiceGroup(id: $0, title: titles[$0] ?? $0, choices: members[$0] ?? []) }
        if !local.isEmpty { groups.append(ModelChoiceGroup(id: "local", title: "On This Device", choices: local)) }
        return groups
    }
}
