// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AIModelOptions

/// A concrete image-generation model served by one configured remote connection.
public struct ImageGenerationModelChoice: Identifiable, Hashable, Sendable {
    public let connectionID: String
    public let connectionName: String
    public let modelID: String

    public init(connectionID: String, connectionName: String, modelID: String) {
        self.connectionID = connectionID
        self.connectionName = connectionName
        self.modelID = modelID
    }

    public var id: String { "\(connectionID)|\(modelID)" }

    /// Label combining model and connection for display in a picker row.
    public var pickerLabel: String { "\(modelID) · \(connectionName)" }
}

/// Enumerates the image-generation models the user can pick (e.g. in the
/// Gallery's Generate sheet) and shared naming for saved generations.
@MainActor
public enum ImageGenerationCatalog {
    /// All image-generation models across enabled, configured remote connections.
    public static func availableModels(
        providerSettings: ProviderSettings
    ) -> [ImageGenerationModelChoice] {
        var choices: [ImageGenerationModelChoice] = []
        for connection in providerSettings.remoteConnections where connection.isEnabled {
            let adapter = providerSettings.adapter(for: connection)
            guard adapter.isConfigured(connection: connection) else { continue }
            var models = connection.availableModels.isEmpty
                ? [connection.trimmedModel].filter { !$0.isEmpty }
                : connection.availableModels
            if OpenAIRequestCodec.isXAIHost(connection.trimmedBaseURL) {
                for bundled in ModelCapabilityCatalog.bundledXAIImageModelIDs where !models.contains(bundled) {
                    models.append(bundled)
                }
            }
            for modelID in models where OpenAICompatibleAPI.isImageGenerationModel(modelID) {
                let choice = ImageGenerationModelChoice(
                    connectionID: connection.id,
                    connectionName: connection.trimmedName,
                    modelID: modelID
                )
                if !choices.contains(choice) {
                    choices.append(choice)
                }
            }
        }
        return choices
    }

    /// Image models that can take a source photo and change it (`/images/edits`).
    public static func availableEditModels(
        providerSettings: ProviderSettings
    ) -> [ImageGenerationModelChoice] {
        availableModels(providerSettings: providerSettings).filter {
            OpenAICompatibleAPI.isImageEditModel($0.modelID)
        }
    }

    /// Derives a short, filesystem-safe PNG filename from a generation prompt.
    public static func filename(for prompt: String) -> String {
        let slug = prompt.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { result, character in
                if character == "-", result.hasSuffix("-") { return }
                result.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .prefix(40)
        let base = slug.isEmpty ? "generated-image" : String(slug)
        return "\(base).png"
    }
}
