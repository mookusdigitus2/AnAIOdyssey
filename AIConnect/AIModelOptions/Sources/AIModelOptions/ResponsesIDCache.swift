// SPDX-License-Identifier: MIT
import Foundation

/// Keys a Responses `previous_response_id` by conversation, connection, and model.
///
/// One global id per service leaks context between chats. The conversation
/// owns the id; this cache is only for callers that want a keyed store.
public struct ResponsesIDCache: Equatable, Sendable {
    private var values: [String: String]

    public init(_ values: [String: String] = [:]) {
        self.values = values
    }

    public static func scope(
        connectionID: String,
        modelID: String,
        conversationID: String? = nil
    ) -> String {
        let connection = connectionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let conversation = (conversationID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if conversation.isEmpty {
            return "\(connection)|\(model)"
        }
        return "\(connection)|\(model)|\(conversation)"
    }

    public func id(for scope: String) -> String? {
        values[scope]
    }

    public mutating func set(_ id: String?, scope: String) {
        guard let id, !id.isEmpty else {
            values.removeValue(forKey: scope)
            return
        }
        values[scope] = id
    }

    public mutating func remove(connectionID: String) {
        let prefix = connectionID.trimmingCharacters(in: .whitespacesAndNewlines) + "|"
        values = values.filter { !$0.key.hasPrefix(prefix) }
    }

    public mutating func removeAll() {
        values.removeAll()
    }
}
