// SPDX-License-Identifier: MIT
import SwiftUI
import AIConnect
import AIModelOptions

/// Shared AI configuration screen (remote connections, API keys, Sign in with
/// ChatGPT) that any app can show. Apps inject their own settings objects and
/// choose whether ChatGPT sign-in is offered.
public struct AIConnectionsSettingsForm<AppSections: View>: View {
    @ObservedObject private var providerSettings: ProviderSettings
    @ObservedObject private var featureModelSettings: FeatureModelSettings
    @ObservedObject private var chatGPTAccounts: ChatGPTAccountService
    private let llmService: (any LLMServiceProtocol)?
    private let allowsChatGPTSignIn: Bool
    /// Optional default-model row (the same pushed list as An AI Odyssey's AI Models page).
    private let defaultModelKey: Binding<String>?
    private let defaultModelCaption: String?
    /// The model the default resolves to, for its Options (thinking, context, max output).
    private let defaultModelOptionsKey: String?
    /// Coding-agent apps: grouped tool-aware default picker and per-connection model pages.
    private let modelDetails: ConnectionModelDetails?
    /// App-specific sections shown under the shared ones (e.g. an app's agent options).
    private let appSections: AppSections
    /// When set, the form opens that connection's editor (Change Tool Format).
    @Binding private var pendingConnectionID: String?
    @State private var editingConnection: RemoteConnection?
    @State private var choosingDefaultModel = false

    @MainActor public init(
        providerSettings: ProviderSettings,
        featureModelSettings: FeatureModelSettings,
        chatGPTAccounts: ChatGPTAccountService? = nil,
        llmService: (any LLMServiceProtocol)? = nil,
        allowsChatGPTSignIn: Bool = true,
        defaultModelKey: Binding<String>? = nil,
        defaultModelCaption: String? = nil,
        defaultModelOptionsKey: String? = nil,
        modelDetails: ConnectionModelDetails? = nil,
        pendingConnectionID: Binding<String?> = .constant(nil),
        @ViewBuilder appSections: () -> AppSections
    ) {
        self.appSections = appSections()
        self.defaultModelOptionsKey = defaultModelOptionsKey
        self.modelDetails = modelDetails
        self.defaultModelKey = defaultModelKey
        self.defaultModelCaption = defaultModelCaption
        self.providerSettings = providerSettings
        self.featureModelSettings = featureModelSettings
        self.chatGPTAccounts = chatGPTAccounts ?? .shared
        self.llmService = llmService
        self.allowsChatGPTSignIn = allowsChatGPTSignIn
        _pendingConnectionID = pendingConnectionID
    }

    public var body: some View {
        Form {
            RemoteConnectionsSection(
                providerSettings: providerSettings,
                featureModelSettings: featureModelSettings,
                llmService: llmService,
                editingConnection: $editingConnection,
                allowsChatGPTSignIn: allowsChatGPTSignIn
            )
            if let defaultModelKey {
                Section("Default Model") {
                    if let defaultModelCaption {
                        Text(defaultModelCaption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let modelDetails {
                        LabeledContent("Model") {
                            ToolModelMenu(
                                selectionKey: Binding(
                                    get: { defaultModelOptionsKey ?? defaultModelKey.wrappedValue },
                                    set: { defaultModelKey.wrappedValue = $0 }
                                ),
                                providerSettings: providerSettings,
                                details: modelDetails,
                                accessibilityIdentifier: "feature-model-global-picker"
                            )
                        }
                    } else {
                        Button {
                            choosingDefaultModel = true
                        } label: {
                            LabeledContent("Model", value: modelLabel(defaultModelKey.wrappedValue))
                        }
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier("feature-model-global-picker")
                    }
                    if let defaultModelOptionsKey, !defaultModelOptionsKey.isEmpty {
                        ModelPickerOptionsView(selectionKey: defaultModelOptionsKey, style: .expanded)
                    }
                }
            }
            appSections
        }
        .environmentObject(chatGPTAccounts)
        .environmentObject(providerSettings)
        .accessibilityIdentifier("aiConnectionsSettings")
        .onAppear { openPendingConnection() }
        .onChange(of: pendingConnectionID) { _, _ in openPendingConnection() }
        #if os(iOS)
        .navigationDestination(isPresented: $choosingDefaultModel) {
            if let defaultModelKey {
                SettingsModelChoiceList(
                    title: "Default Model",
                    selectionKey: Binding(
                        get: { defaultModelKey.wrappedValue },
                        set: { defaultModelKey.wrappedValue = $0; choosingDefaultModel = false }
                    ),
                    choices: ConfiguredModelRegistry.pickerChoices(
                        providerSettings: providerSettings,
                        selectionKey: defaultModelKey.wrappedValue,
                        offerLocalMLX: false
                    ),
                    resetLabel: "Use First Available",
                    resetDisabled: defaultModelKey.wrappedValue.isEmpty,
                    onReset: { defaultModelKey.wrappedValue = ""; choosingDefaultModel = false }
                )
            }
        }
        .navigationDestination(item: $editingConnection) { editor($0) }
        #else
        .sheet(item: $editingConnection) { connection in NavigationStack { editor(connection) } }
        #endif
    }

    private func openPendingConnection() {
        guard let id = pendingConnectionID, !id.isEmpty,
              let connection = providerSettings.connection(id: id) else { return }
        editingConnection = connection
        pendingConnectionID = nil
    }

    private func modelLabel(_ key: String) -> String {
        guard !key.isEmpty,
              let choice = ConfiguredModelRegistry.choice(forSelectionKey: key, providerSettings: providerSettings)
        else { return "First available" }
        return choice.pickerLabel
    }

    private func editor(_ connection: RemoteConnection) -> some View {
        RemoteConnectionEditorView(
            connection: connection,
            providerSettings: providerSettings,
            onSave: { updated in
                // Keep a server answer that arrived while the page was open.
                providerSettings.updateConnection(updated.withServerDetection(from: providerSettings.connection(id: updated.id)))
                editingConnection = nil
                // Tell LM Studio apart from other servers as soon as the connection is added or changed.
                Task { await RemoteLLMService(settings: providerSettings).detectServer(for: updated.id) }
            },
            onCancel: { editingConnection = nil },
            onSignOut: {
                Task {
                    await chatGPTAccounts.signOut(connection: connection, providerSettings: providerSettings)
                    editingConnection = nil
                }
            },
            modelDetails: modelDetails
        )
        .environmentObject(chatGPTAccounts)
    }
}

public extension AIConnectionsSettingsForm where AppSections == EmptyView {
    /// The shared screen with no app-specific sections.
    @MainActor init(
        providerSettings: ProviderSettings,
        featureModelSettings: FeatureModelSettings,
        chatGPTAccounts: ChatGPTAccountService? = nil,
        llmService: (any LLMServiceProtocol)? = nil,
        allowsChatGPTSignIn: Bool = true,
        defaultModelKey: Binding<String>? = nil,
        defaultModelCaption: String? = nil,
        defaultModelOptionsKey: String? = nil,
        modelDetails: ConnectionModelDetails? = nil,
        pendingConnectionID: Binding<String?> = .constant(nil)
    ) {
        self.init(
            providerSettings: providerSettings,
            featureModelSettings: featureModelSettings,
            chatGPTAccounts: chatGPTAccounts,
            llmService: llmService,
            allowsChatGPTSignIn: allowsChatGPTSignIn,
            defaultModelKey: defaultModelKey,
            defaultModelCaption: defaultModelCaption,
            defaultModelOptionsKey: defaultModelOptionsKey,
            modelDetails: modelDetails,
            pendingConnectionID: pendingConnectionID,
            appSections: { EmptyView() }
        )
    }
}
