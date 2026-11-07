// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AnAIOdysseyCore
import AIModelOptions

/// User preferences for multi-agent orchestration: controller selection, tags, voice.
@MainActor
public final class AgentRegistrySettings: ObservableObject {
    private enum Keys {
        static let controllerAgentID = "anaiodyssey.agent.controllerID"
        static let cursorCLIPath = "anaiodyssey.agent.cursorCLIPath"
        static let elevenLabsAPIKey = "anaiodyssey.voice.elevenLabsAPIKey"
        static let elevenLabsVoiceID = "anaiodyssey.voice.elevenLabsVoiceID"
        static let elevenLabsAddedVoices = "anaiodyssey.voice.elevenLabsAddedVoices"
        static let elevenLabsModelID = "anaiodyssey.voice.elevenLabsModelID"
        static let openAIVoiceModel = "anaiodyssey.voice.openAIModel"
        static let openAIVoiceID = "anaiodyssey.voice.openAIVoiceID"
        static let xaiVoiceID = "anaiodyssey.voice.xaiVoiceID"
        static let systemVoiceID = "anaiodyssey.voice.systemVoiceID"
        static let voiceProvider = "anaiodyssey.voice.provider"
    }

    public static let defaultControllerID = "local-llm"
    public static let defaultRemoteAgentID = "remote-openai"

    @Published public var controllerAgentID: String {
        didSet { defaults.set(controllerAgentID, forKey: Keys.controllerAgentID) }
    }

    @Published public var cursorCLIPath: String {
        didSet { defaults.set(cursorCLIPath, forKey: Keys.cursorCLIPath) }
    }

    public static let defaultElevenLabsVoiceID = VoiceCatalog.defaultElevenLabsVoiceID
    public static let defaultElevenLabsModelID = VoiceCatalog.defaultElevenLabsModelID
    public static let defaultOpenAIVoiceModel = VoiceCatalog.defaultOpenAIModelID
    public static let defaultOpenAIVoiceID = VoiceCatalog.defaultOpenAIVoiceID
    public static let defaultXAIVoiceID = VoiceCatalog.defaultXAIVoiceID

    @Published public var elevenLabsAPIKey: String {
        didSet { defaults.set(elevenLabsAPIKey, forKey: Keys.elevenLabsAPIKey) }
    }

    @Published public var elevenLabsVoiceID: String {
        didSet { defaults.set(elevenLabsVoiceID, forKey: Keys.elevenLabsVoiceID) }
    }

    @Published public var elevenLabsAddedVoicesJSON: String {
        didSet { defaults.set(elevenLabsAddedVoicesJSON, forKey: Keys.elevenLabsAddedVoices) }
    }

    public var elevenLabsAddedVoices: [ElevenLabsVoiceRecord] {
        get { ElevenLabsTTSCodec.decodeAddedVoices(elevenLabsAddedVoicesJSON) }
        set { elevenLabsAddedVoicesJSON = ElevenLabsTTSCodec.encodeAddedVoices(newValue) }
    }

    public func addElevenLabsVoice(_ record: ElevenLabsVoiceRecord) {
        var current = elevenLabsAddedVoices
        current.removeAll { $0.voiceID == record.voiceID }
        current.insert(record, at: 0)
        elevenLabsAddedVoices = current
        elevenLabsVoiceID = record.voiceID
    }

    public func removeElevenLabsAddedVoice(id: String) {
        var current = elevenLabsAddedVoices
        current.removeAll { $0.voiceID == id }
        elevenLabsAddedVoices = current
    }

    @Published public var elevenLabsModelID: String {
        didSet { defaults.set(elevenLabsModelID, forKey: Keys.elevenLabsModelID) }
    }

    @Published public var openAIVoiceModel: String {
        didSet { defaults.set(openAIVoiceModel, forKey: Keys.openAIVoiceModel) }
    }

    @Published public var openAIVoiceID: String {
        didSet { defaults.set(openAIVoiceID, forKey: Keys.openAIVoiceID) }
    }

    @Published public var xaiVoiceID: String {
        didSet { defaults.set(xaiVoiceID, forKey: Keys.xaiVoiceID) }
    }

    @Published public var systemVoiceID: String {
        didSet { defaults.set(systemVoiceID, forKey: Keys.systemVoiceID) }
    }

    @Published public var voiceProvider: String {
        didSet { defaults.set(voiceProvider, forKey: Keys.voiceProvider) }
    }

    private let defaults: UserDefaults
    private var cloudObserver: NSObjectProtocol?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        controllerAgentID = defaults.string(forKey: Keys.controllerAgentID) ?? Self.defaultControllerID
        cursorCLIPath = defaults.string(forKey: Keys.cursorCLIPath) ?? "cursor"
        elevenLabsAPIKey = defaults.string(forKey: Keys.elevenLabsAPIKey) ?? ""
        elevenLabsVoiceID = defaults.string(forKey: Keys.elevenLabsVoiceID) ?? Self.defaultElevenLabsVoiceID
        elevenLabsAddedVoicesJSON = defaults.string(forKey: Keys.elevenLabsAddedVoices) ?? "[]"
        elevenLabsModelID = defaults.string(forKey: Keys.elevenLabsModelID) ?? Self.defaultElevenLabsModelID
        openAIVoiceModel = defaults.string(forKey: Keys.openAIVoiceModel) ?? Self.defaultOpenAIVoiceModel
        openAIVoiceID = defaults.string(forKey: Keys.openAIVoiceID) ?? Self.defaultOpenAIVoiceID
        xaiVoiceID = defaults.string(forKey: Keys.xaiVoiceID) ?? Self.defaultXAIVoiceID
        systemVoiceID = defaults.string(forKey: Keys.systemVoiceID) ?? ""
        voiceProvider = defaults.string(forKey: Keys.voiceProvider) ?? VoiceProvider.system.rawValue
        cloudObserver = NotificationCenter.default.addObserver(
            forName: CloudDefaultsSync.didApplyRemoteChanges,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadFromDefaults() }
        }
    }

    deinit {
        if let cloudObserver { NotificationCenter.default.removeObserver(cloudObserver) }
    }

    public var resolvedControllerID: String {
        controllerAgentID
    }

    private func reloadFromDefaults() {
        controllerAgentID = defaults.string(forKey: Keys.controllerAgentID) ?? Self.defaultControllerID
        cursorCLIPath = defaults.string(forKey: Keys.cursorCLIPath) ?? "cursor"
        elevenLabsAPIKey = defaults.string(forKey: Keys.elevenLabsAPIKey) ?? ""
        elevenLabsVoiceID = defaults.string(forKey: Keys.elevenLabsVoiceID) ?? Self.defaultElevenLabsVoiceID
        elevenLabsAddedVoicesJSON = defaults.string(forKey: Keys.elevenLabsAddedVoices) ?? "[]"
        elevenLabsModelID = defaults.string(forKey: Keys.elevenLabsModelID) ?? Self.defaultElevenLabsModelID
        openAIVoiceModel = defaults.string(forKey: Keys.openAIVoiceModel) ?? Self.defaultOpenAIVoiceModel
        openAIVoiceID = defaults.string(forKey: Keys.openAIVoiceID) ?? Self.defaultOpenAIVoiceID
        xaiVoiceID = defaults.string(forKey: Keys.xaiVoiceID) ?? Self.defaultXAIVoiceID
        systemVoiceID = defaults.string(forKey: Keys.systemVoiceID) ?? ""
        voiceProvider = defaults.string(forKey: Keys.voiceProvider) ?? VoiceProvider.system.rawValue
    }

    public func voiceID(for provider: VoiceProvider) -> String {
        switch provider {
        case .system: return systemVoiceID
        case .elevenLabs: return elevenLabsVoiceID
        case .openai: return openAIVoiceID
        case .xai: return xaiVoiceID
        case .appleIntelligence: return ""
        }
    }

    public func setVoiceID(_ voiceID: String, for provider: VoiceProvider) {
        switch provider {
        case .system: systemVoiceID = voiceID
        case .elevenLabs: elevenLabsVoiceID = voiceID
        case .openai: openAIVoiceID = voiceID
        case .xai: xaiVoiceID = voiceID
        case .appleIntelligence: break
        }
    }
}
