// SPDX-License-Identifier: MIT
import Foundation
import AIModelOptions

/// LM Studio's OpenAI-compatible `/v1/models` lists ids only. Tool use is described
/// by `GET /api/v1/models` (`type`, `capabilities.trained_for_tool_use`) and, on
/// 0.3.x, `GET /api/v0/models` (`capabilities: ["tool_use"]`).
public enum LMStudioNativeModels {
    /// Native lists for a connection that is or may be LM Studio (its preset Tool Format, or any
    /// OpenAI-style server on this device or the local network, on any port).
    /// v1 is the documented list; v0 is the older capabilities array.
    public static func nativeListURLs(for connection: RemoteConnection) -> [URL] {
        [
            url(for: connection, suffix: "/api/v1/models"),
            url(for: connection, suffix: "/api/v0/models"),
            url(for: connection, suffix: "/v1/models"),
        ].compactMap { $0 }
    }

    /// The v0 list. Kept so callers that only know the 0.3 endpoint still resolve.
    public static func url(for connection: RemoteConnection) -> URL? {
        url(for: connection, suffix: "/api/v0/models")
    }

    /// Copies tool support onto alias ids (`selected_variant`, loaded instance id) that
    /// `/v1/models` may return in place of `key`.
    public static func includingAliases(_ models: [RemoteModelDescriptor], json: Data) -> [RemoteModelDescriptor] {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return models }
        let rows = (object["models"] as? [[String: Any]]) ?? (object["data"] as? [[String: Any]]) ?? []
        let byID = Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set(models.map(\.id))
        var result = models
        for row in rows {
            let primary = (row["key"] as? String) ?? (row["id"] as? String) ?? (row["slug"] as? String)
            guard let primary, let base = byID[primary] else { continue }
            for alias in LMStudioToolProtocol.aliasIDs(in: row) where seen.insert(alias).inserted {
                result.append(
                    RemoteModelDescriptor(
                        id: alias,
                        created: base.created,
                        supportsTools: base.supportsTools,
                        contextWindowTokens: base.contextWindowTokens,
                        supportsVision: base.supportsVision,
                        reasoningEfforts: base.reasoningEfforts,
                        defaultReasoningEffort: base.defaultReasoningEffort
                    )
                )
            }
        }
        return result
    }

    /// Fills in tool support the OpenAI-style list didn't carry, keeping its ids and order.
    public static func merge(_ models: [RemoteModelDescriptor], native: [RemoteModelDescriptor]) -> [RemoteModelDescriptor] {
        let extra = Dictionary(native.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return models.map { model in
            guard let native = extra[model.id] else { return model }
            var model = model
            if model.supportsTools == nil { model.supportsTools = native.supportsTools }
            if model.contextWindowTokens == nil { model.contextWindowTokens = native.contextWindowTokens }
            if model.supportsVision == nil { model.supportsVision = native.supportsVision }
            if model.reasoningEfforts.isEmpty { model.reasoningEfforts = native.reasoningEfforts }
            if model.defaultReasoningEffort == nil { model.defaultReasoningEffort = native.defaultReasoningEffort }
            return model
        }
    }

    /// True when `json` is LM Studio's own `/api/v1/models` or `/api/v0/models` list: rows with
    /// LM Studio's model `type` (llm, vlm, embedding) and its `key` (v1) or `compatibility_type` /
    /// `arch` / `state` (v0). A plain OpenAI `/v1/models` list is not.
    public static func isLMStudioList(_ json: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return false }
        let types: Set<String> = ["llm", "vlm", "embedding", "embeddings", "decision"]
        func isLMStudioType(_ row: [String: Any]) -> Bool {
            guard let type = (row["type"] as? String)?.lowercased() else { return false }
            return types.contains(type)
        }
        if let rows = object["models"] as? [[String: Any]],
           rows.contains(where: { isLMStudioType($0) && $0["key"] is String }) {
            return true
        }
        if let rows = object["data"] as? [[String: Any]],
           rows.contains(where: { row in
               isLMStudioType(row) && (row["compatibility_type"] != nil || row["arch"] != nil || row["state"] != nil)
           }) {
            return true
        }
        return false
    }

    /// `suffix` on the server root (the base URL without `/v1`), for a connection that may be LM
    /// Studio or Ollama.
    static func rootURL(for connection: RemoteConnection, suffix: String) -> URL? {
        url(for: connection, suffix: suffix)
    }

    private static func url(for connection: RemoteConnection, suffix: String) -> URL? {
        guard var components = URLComponents(string: connection.trimmedBaseURL),
              components.host != nil,
              connection.mayServeLMStudio else { return nil }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/v1") { path.removeLast(3) }
        components.path = path + suffix
        components.query = nil
        return components.url
    }
}
