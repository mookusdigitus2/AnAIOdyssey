// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import XCTest
import AnAIOdysseyAI

@MainActor
final class FeatureModelSettingsTests: XCTestCase {
    func testStoresAndRetrievesFeatureDefault() {
        let defaults = UserDefaults(suiteName: "FeatureModelSettingsTests")!
        defaults.removePersistentDomain(forName: "FeatureModelSettingsTests")
        let settings = FeatureModelSettings(defaults: defaults)

        settings.setSelectionKey("remote|openai|gpt-4o-mini", for: .chat)
        XCTAssertEqual(settings.selectionKey(for: .chat), "remote|openai|gpt-4o-mini")
    }

    func testGlobalDefaultAppliesWhenFeatureOverrideUnset() {
        let defaults = UserDefaults(suiteName: "FeatureModelSettingsTestsGlobal")!
        defaults.removePersistentDomain(forName: "FeatureModelSettingsTestsGlobal")
        let providerSettings = ProviderSettings()
        providerSettings.remoteConnections = [
            RemoteConnection(
                id: "openai",
                name: "OpenAI",
                apiBaseURL: "https://api.openai.com/v1",
                apiKey: "secret",
                defaultModel: "gpt-4o-mini",
                availableModels: ["gpt-4o-mini", "gpt-4o"],
                encoding: .openAIChatCompletions
            ),
        ]
        let agentSettings = AgentRegistrySettings()
        let settings = FeatureModelSettings(defaults: defaults)
        settings.setGlobalSelectionKey("remote|openai|gpt-4o")

        let resolved = settings.resolvedSelectionKey(
            for: .research,
            providerSettings: providerSettings,
            agentSettings: agentSettings
        )
        XCTAssertEqual(resolved, "remote|openai|gpt-4o")
    }

    func testFeatureOverrideTakesPrecedenceOverGlobalDefault() {
        let defaults = UserDefaults(suiteName: "FeatureModelSettingsTestsOverride")!
        defaults.removePersistentDomain(forName: "FeatureModelSettingsTestsOverride")
        let providerSettings = ProviderSettings()
        providerSettings.remoteConnections = [
            RemoteConnection(
                id: "openai",
                name: "OpenAI",
                apiBaseURL: "https://api.openai.com/v1",
                apiKey: "secret",
                defaultModel: "gpt-4o-mini",
                availableModels: ["gpt-4o-mini", "gpt-4o"],
                encoding: .openAIChatCompletions
            ),
        ]
        let agentSettings = AgentRegistrySettings()
        let settings = FeatureModelSettings(defaults: defaults)
        settings.setGlobalSelectionKey("remote|openai|gpt-4o")
        settings.setSelectionKey("remote|openai|gpt-4o-mini", for: .chat)

        let resolved = settings.resolvedSelectionKey(
            for: .chat,
            providerSettings: providerSettings,
            agentSettings: agentSettings
        )
        XCTAssertEqual(resolved, "remote|openai|gpt-4o-mini")
    }

    func testResolvedSelectionKeyFallsBackToAgentDefault() {
        let providerSettings = ProviderSettings()
        let agentSettings = AgentRegistrySettings()
        let defaults = UserDefaults(suiteName: "FeatureModelSettingsTests2")!
        defaults.removePersistentDomain(forName: "FeatureModelSettingsTests2")
        let featureSettings = FeatureModelSettings(defaults: defaults)

        let resolved = featureSettings.resolvedSelectionKey(
            for: .research,
            providerSettings: providerSettings,
            agentSettings: agentSettings
        )
        XCTAssertFalse(resolved.isEmpty)
    }

    func testTabDefaultsDoNotIncludeCompareSlots() {
        XCTAssertEqual(
            WorkspaceFeature.allCases.map(\.rawValue),
            ["chat", "documents", "research", "email", "tasks"]
        )
    }

    func testSelectingAGlobalDefaultDoesNotClearUnlessResetIsCalled() {
        let defaults = UserDefaults(suiteName: "FeatureModelSettingsTestsSelectKeep")!
        defaults.removePersistentDomain(forName: "FeatureModelSettingsTestsSelectKeep")
        let settings = FeatureModelSettings(defaults: defaults)
        let key = "remote|openai|gpt-4o"
        settings.setGlobalSelectionKey(key)
        XCTAssertEqual(settings.globalSelectionKey(), key)
        XCTAssertTrue(settings.hasGlobalOverride)
        settings.clearGlobalSelectionKey()
        XCTAssertNil(settings.globalSelectionKey())
        XCTAssertFalse(settings.hasGlobalOverride)
    }

    func testSettingsRevisionIncrementsWhenDefaultsChange() {
        let defaults = UserDefaults(suiteName: "FeatureModelSettingsTestsRevision")!
        defaults.removePersistentDomain(forName: "FeatureModelSettingsTestsRevision")
        let settings = FeatureModelSettings(defaults: defaults)
        let initial = settings.settingsRevision

        settings.setGlobalSelectionKey("localMLX|llama3_2_1B_4bit")
        XCTAssertGreaterThan(settings.settingsRevision, initial)
    }

    func testRemoveReferencesClearsDeletedConnection() {
        let defaults = UserDefaults(suiteName: "FeatureModelSettingsTests3")!
        defaults.removePersistentDomain(forName: "FeatureModelSettingsTests3")
        let featureSettings = FeatureModelSettings(defaults: defaults)
        featureSettings.setSelectionKey("remote|deleted-id|gpt-4o-mini", for: .email)
        featureSettings.setGlobalSelectionKey("remote|deleted-id|gpt-4o")

        featureSettings.removeReferences(toConnectionID: "deleted-id")

        XCTAssertNil(featureSettings.selectionKey(for: .email))
        XCTAssertNil(featureSettings.globalSelectionKey())
    }
}

@MainActor
final class ProviderSettingsDeletionTests: XCTestCase {
    func testRemoveLastConnectionClearsLegacyFields() {
        let defaults = UserDefaults(suiteName: "ProviderSettingsDeletionTests")!
        defaults.removePersistentDomain(forName: "ProviderSettingsDeletionTests")
        let settings = ProviderSettings(defaults: defaults)
        settings.remoteConnections = [
            RemoteConnection(
                id: "only",
                name: "OpenAI",
                apiBaseURL: "https://api.openai.com/v1",
                apiKey: "secret",
                defaultModel: "gpt-4o-mini",
                encoding: .openAIChatCompletions
            ),
        ]

        settings.removeConnection(id: "only")

        XCTAssertTrue(settings.remoteConnections.isEmpty)
        XCTAssertFalse(settings.isRemoteConfigured)
        XCTAssertEqual(settings.apiKey, "")
        XCTAssertEqual(settings.remoteModel, ProviderSettings.defaultRemoteModel)
    }
}
