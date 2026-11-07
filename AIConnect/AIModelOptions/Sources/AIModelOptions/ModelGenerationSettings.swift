// SPDX-License-Identifier: MIT
import Foundation

/// Persists per-selection generation options.
///
/// Keys prefer the picker selection key (`backend|connection|model` for remote,
/// `backend|model` for local). Older `connection|model` entries are still read.
public enum ModelGenerationSettings {
    static let defaultsKey = "anaiodyssey.remote.modelGenerationOptions"
    public static let didChangeNotification = Notification.Name("anaiodyssey.modelGenerationOptions.didChange")

    public static func options(forSelectionKey selectionKey: String) -> ModelGenerationOptions {
        options(forSelectionKey: selectionKey, fallbackConnectionID: nil, fallbackModelID: nil)
    }

    public static func options(
        forSelectionKey selectionKey: String,
        fallbackConnectionID: String?,
        fallbackModelID: String?
    ) -> ModelGenerationOptions {
        let all = loadAll()
        if let value = all[selectionKey] {
            return value
        }
        if let fallbackConnectionID, let fallbackModelID,
           let value = all[legacyKey(fallbackConnectionID, fallbackModelID)] {
            return value
        }
        return ModelGenerationOptions()
    }

    public static func options(connectionID: String, modelID: String) -> ModelGenerationOptions {
        options(
            forSelectionKey: remoteSelectionKey(connectionID: connectionID, modelID: modelID),
            fallbackConnectionID: connectionID,
            fallbackModelID: modelID
        )
    }

    public static func setOptions(_ options: ModelGenerationOptions, forSelectionKey selectionKey: String) {
        var all = loadAll()
        if options.isEmpty {
            all.removeValue(forKey: selectionKey)
        } else {
            all[selectionKey] = options
        }
        save(all)
    }

    public static func setOptions(
        _ options: ModelGenerationOptions,
        connectionID: String,
        modelID: String
    ) {
        setOptions(options, forSelectionKey: remoteSelectionKey(connectionID: connectionID, modelID: modelID))
    }

    /// Drops stored options for a deleted connection (new and legacy keys).
    public static func removeOptions(connectionID: String) {
        let prefixes = [legacyKeyPrefix(connectionID), "remote|\(connectionID)|"]
        let all = loadAll().filter { key, _ in
            !prefixes.contains { key.hasPrefix($0) }
        }
        save(all)
    }

    public static func remoteSelectionKey(connectionID: String, modelID: String) -> String {
        "remote|\(connectionID)|\(modelID)"
    }

    // MARK: - Private

    private static func legacyKey(_ connectionID: String, _ modelID: String) -> String {
        "\(connectionID)|\(modelID)"
    }

    private static func legacyKeyPrefix(_ connectionID: String) -> String {
        connectionID + "|"
    }

    private static func loadAll() -> [String: ModelGenerationOptions] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: ModelGenerationOptions].self, from: data)
        else {
            return [:]
        }
        return decoded
    }

    private static func save(_ all: [String: ModelGenerationOptions]) {
        if all.isEmpty {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
