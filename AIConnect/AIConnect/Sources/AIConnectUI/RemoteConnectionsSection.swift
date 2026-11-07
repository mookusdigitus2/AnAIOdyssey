// SPDX-License-Identifier: MIT
import SwiftUI
import AIConnect
import AIModelOptions

/// Settings table for managing multiple remote model provider connections.
///
/// The connection editor is presented by the parent ``SettingsView`` (navigation
/// push on iOS, sheet on macOS) via ``editingConnection``. Settings itself is
/// already a sheet on iPhone, so nesting another sheet here dismisses before the
/// user can type.
public struct RemoteConnectionsSection: View {
    @ObservedObject public var providerSettings: ProviderSettings
    @ObservedObject public var featureModelSettings: FeatureModelSettings
    public var llmService: (any LLMServiceProtocol)?
    @Binding public var editingConnection: RemoteConnection?
    /// Per-app switch: when false the "Continue with ChatGPT" offer is hidden entirely.
    public var allowsChatGPTSignIn: Bool = true

    public init(
        providerSettings: ProviderSettings,
        featureModelSettings: FeatureModelSettings,
        llmService: (any LLMServiceProtocol)?,
        editingConnection: Binding<RemoteConnection?>,
        allowsChatGPTSignIn: Bool = true
    ) {
        self.providerSettings = providerSettings
        self.featureModelSettings = featureModelSettings
        self.llmService = llmService
        _editingConnection = editingConnection
        self.allowsChatGPTSignIn = allowsChatGPTSignIn
    }
    @EnvironmentObject private var chatGPTAccounts: ChatGPTAccountService
    @State private var connectionPendingDeletion: RemoteConnection?
    @State private var chatGPTError: String?
    @State private var chatGPTIneligible: String?
    @State private var connectionTestResults: [String: String] = [:]
    @State private var connectionTestErrors: [String: String] = [:]
    @State private var testingConnectionID: String?
    @State private var queryingConnectionID: String?

    public var body: some View {
        Section("Remote Model Connections") {
            Text("Each connection has its own URL, credentials, and tool format.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if showsChatGPTOfferBlock {
            VStack(alignment: .leading, spacing: 8) {
                if !hasPlanAccount {
                    ChatGPTPlanOffer(isBusy: chatGPTAccounts.isSigningIn) {
                        Task { await signInWithChatGPT() }
                    }
                }
                if let chatGPTIneligible {
                    ConnectionStatusMessage(kind: .error, text: chatGPTIneligible)
                }
                if let chatGPTError {
                    ConnectionStatusMessage(kind: .error, text: chatGPTError)
                }
                if let notice = chatGPTAccounts.lastError, chatGPTError == nil {
                    ConnectionStatusMessage(kind: .info, text: notice)
                }
            }
            }

            if providerSettings.remoteConnections.isEmpty {
                Text("No remote connections yet. Add one below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(providerSettings.remoteConnections) { connection in
                    connectionRow(connection)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Add OpenAI") { providerSettings.addPresetOpenAI() }
                        .buttonStyle(.bordered)
                    Button("Add xAI") { providerSettings.addPresetXAI() }
                        .buttonStyle(.bordered)
                }
                HStack {
                    Button("Add Gemini") { providerSettings.addPresetGemini() }
                        .buttonStyle(.bordered)
                    Button("Add LM Studio") { providerSettings.addPresetLMStudio() }
                        .buttonStyle(.bordered)
                }
            }

            Button("Add Custom Connection") {
                openEditor(RemoteConnection(name: "New Connection", apiBaseURL: ""))
            }
            .buttonStyle(.bordered)
        }
        .destructiveDeleteAlert(
            "Delete Remote Connection?",
            item: $connectionPendingDeletion,
            message: { connection in
                "“\(connection.trimmedName.isEmpty ? "Unnamed" : connection.trimmedName)” will be removed. Feature tabs using this provider will fall back to their other defaults."
            },
            confirmAction: deleteConnection
        )
        .chatGPTPlanNotice(chatGPTAccounts)
    }

    /// A ChatGPT account with plan usage already on hides the sign-in offer.
    private var hasPlanAccount: Bool {
        providerSettings.remoteConnections.contains {
            $0.usesChatGPTAccount && $0.chatgptPlanEligible == true && chatGPTAccounts.hasCredentials(for: $0.id)
        }
    }

    @ViewBuilder
    private func connectionRow(_ connection: RemoteConnection) -> some View {
        let adapter = providerSettings.adapter(for: connection)
        let configured = adapter.isConfigured(connection: connection)

        VStack(alignment: .leading, spacing: 6) {
            // Keep the enable toggle outside the open-editor control so taps don't
            // race between toggling and presenting the editor.
            HStack(alignment: .top, spacing: 12) {
                Button {
                    openEditor(connection)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(connection.trimmedName.isEmpty ? "Unnamed" : connection.trimmedName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(connectionSubtitle(connection))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Toggle("Enabled", isOn: binding(for: connection.id, keyPath: \.isEnabled))
                    .labelsHidden()
            }

            if !connection.availableModels.isEmpty {
                let count = connection.availableModels.count
                let defaultLabel = connection.trimmedModel.isEmpty
                    ? ""
                    : "Default: \(connection.trimmedModel) · "
                Text("\(defaultLabel)\(count) saved model\(count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(configured ? "Ready" : adapter.configurationHint(connection: connection))
                .font(.caption)
                .foregroundStyle(configured ? Color.secondary : Color.red)

            if connection.usesChatGPTAccount {
                chatGPTAccountControls(connection)
            }

            HStack {
                Button("Edit") {
                    openEditor(connection)
                }
                let modelButtonLabel = connection.availableModels.isEmpty
                    ? "Query Models"
                    : "Refresh Models"
                Button(queryingConnectionID == connection.id ? "Querying…" : modelButtonLabel) {
                    Task { await queryModels(for: connection.id) }
                }
                .disabled(!connection.isEnabled || queryingConnectionID != nil)
                Button(testingConnectionID == connection.id ? "Testing…" : "Test") {
                    Task { await testConnection(connection.id) }
                }
                .disabled(!connection.isEnabled || testingConnectionID != nil)
            }
            .buttonStyle(.borderless)
            .font(.caption)

            if let result = connectionTestResults[connection.id] {
                ConnectionStatusMessage(kind: .success, text: result, scrollable: true)
            }
            if let error = connectionTestErrors[connection.id] {
                ConnectionStatusMessage(kind: .error, text: error, scrollable: true)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Edit") {
                openEditor(connection)
            }
            Button("Delete", role: .destructive) {
                connectionPendingDeletion = connection
            }
        }
    }

    /// Hides the empty offer row once a plan account exists and nothing needs saying.
    private var showsChatGPTOfferBlock: Bool {
        guard allowsChatGPTSignIn else { return false }
        return !hasPlanAccount || chatGPTIneligible != nil || chatGPTError != nil
            || chatGPTAccounts.lastError != nil
    }

    @ViewBuilder
    private func chatGPTAccountControls(_ connection: RemoteConnection) -> some View {
        let signedIn = chatGPTAccounts.hasCredentials(for: connection.id)
        VStack(alignment: .leading, spacing: 6) {
            if !signedIn {
                Text(ChatGPTAccountError.signInRequired.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.red)
                ContinueWithChatGPTButton(isBusy: chatGPTAccounts.isSigningIn) {
                    Task { await signInWithChatGPT(existing: connection) }
                }
            } else if connection.chatgptPlanEligible == true {
                ChatGPTPlanInUseLabel()
            } else {
                Text(ChatGPTOAuthCodec.ineligibleUserMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Enable ChatGPT plan usage") {
                    Task { await signInWithChatGPT(existing: connection, requestPlanConsent: true) }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(chatGPTAccounts.isSigningIn)
            }
            Button("Sign Out of ChatGPT") {
                Task { await chatGPTAccounts.signOut(connection: connection, providerSettings: providerSettings) }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    private func connectionSubtitle(_ connection: RemoteConnection) -> String {
        if connection.usesChatGPTAccount {
            let account = connection.chatgptEmail ?? "ChatGPT account"
            if !chatGPTAccounts.hasCredentials(for: connection.id) {
                return "\(account) · Sign in again"
            }
            if connection.chatgptPlanEligible == true {
                return "\(account) · \(ChatGPTOAuthCodec.planInUseLabel)"
            }
            if providerSettings.apiKeyFallbackConnection(for: connection) != nil {
                return "\(account) · Plan usage off · using your API key"
            }
            return "\(account) · Plan usage not granted"
        }
        return "\(connection.encoding.displayName) · \(connection.trimmedBaseURL)"
    }

    private func signInWithChatGPT(existing: RemoteConnection? = nil, requestPlanConsent: Bool = false) async {
        chatGPTError = nil
        chatGPTIneligible = nil
        do {
            try await chatGPTAccounts.signIn(
                into: providerSettings,
                existingConnectionID: existing?.id,
                requestPlanConsent: requestPlanConsent
            )
        } catch ChatGPTAccountError.ineligible {
            chatGPTIneligible = ChatGPTOAuthCodec.ineligibleUserMessage
        } catch ChatGPTAccountError.cancelled {
            // User closed the sign-in sheet.
        } catch {
            chatGPTError = error.localizedDescription
        }
    }

    private func openEditor(_ connection: RemoteConnection) {
        editingConnection = connection
    }

    private func binding(
        for id: String,
        keyPath: WritableKeyPath<RemoteConnection, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: {
                providerSettings.connection(id: id).map { $0[keyPath: keyPath] } ?? false
            },
            set: { newValue in
                guard var connection = providerSettings.connection(id: id) else { return }
                connection[keyPath: keyPath] = newValue
                providerSettings.updateConnection(connection)
            }
        )
    }

    private func deleteConnection(_ connection: RemoteConnection) {
        let connectionID = connection.id
        providerSettings.removeConnection(id: connectionID)
        featureModelSettings.removeReferences(toConnectionID: connectionID)
        connectionTestResults.removeValue(forKey: connectionID)
        connectionTestErrors.removeValue(forKey: connectionID)
        connectionPendingDeletion = nil

        if let llmService {
            if (llmService as? any RemoteConnectionSelectable)?.selectedRemoteConnectionID == connectionID {
                (llmService as? any RemoteConnectionSelectable)?.selectedRemoteConnectionID = nil
            }
            if (llmService as? RemoteLLMCapable)?.activeConnectionID == connectionID {
                (llmService as? RemoteLLMCapable)?.setActiveConnection(id: nil, modelID: nil)
            }
        }
    }

    private func queryModels(for connectionID: String) async {
        queryingConnectionID = connectionID
        connectionTestErrors[connectionID] = nil
        defer { queryingConnectionID = nil }

        let service = RemoteLLMService(settings: providerSettings)
        do {
            let models = try await service.queryModels(for: connectionID)
            connectionTestResults[connectionID] = "Found \(models.count) model(s)."
        } catch {
            connectionTestErrors[connectionID] = error.localizedDescription
        }
    }

    private func testConnection(_ connectionID: String) async {
        testingConnectionID = connectionID
        connectionTestErrors[connectionID] = nil
        connectionTestResults[connectionID] = nil
        defer { testingConnectionID = nil }

        let service = RemoteLLMService(settings: providerSettings)
        do {
            let response = try await service.testConnection(connectionID: connectionID)
            connectionTestResults[connectionID] = "Model answered:\n\n\(response)"
        } catch {
            connectionTestErrors[connectionID] = error.localizedDescription
        }
    }
}

/// Editor for a single remote connection. Presented via navigation push on iOS
/// (to avoid nested sheets) and as sheet content on macOS.
public struct RemoteConnectionEditorView: View {
    @State public var connection: RemoteConnection
    public let onSave: (RemoteConnection) -> Void
    public let onCancel: () -> Void
    public var onSignOut: (() -> Void)? = nil
    /// When set, the page lists the connection's models with a default, each model's Options
    /// and its tool support (apps with a coding agent). Odyssey leaves it off.
    public var modelDetails: ConnectionModelDetails? = nil
    /// When set, the Server line follows the saved connection, so a check that finishes while
    /// the page is open shows up.
    public var providerSettings: ProviderSettings? = nil

    public init(
        connection: RemoteConnection,
        onSave: @escaping (RemoteConnection) -> Void,
        onCancel: @escaping () -> Void,
        onSignOut: (() -> Void)? = nil,
        modelDetails: ConnectionModelDetails? = nil
    ) {
        _connection = State(initialValue: connection)
        self.onSave = onSave
        self.onCancel = onCancel
        self.onSignOut = onSignOut
        self.modelDetails = modelDetails
    }

    public init(
        connection: RemoteConnection,
        providerSettings: ProviderSettings,
        onSave: @escaping (RemoteConnection) -> Void,
        onCancel: @escaping () -> Void,
        onSignOut: (() -> Void)? = nil,
        modelDetails: ConnectionModelDetails? = nil
    ) {
        self.init(connection: connection, onSave: onSave, onCancel: onCancel, onSignOut: onSignOut, modelDetails: modelDetails)
        self.providerSettings = providerSettings
    }

    private var apiChoiceBinding: Binding<OpenAIAPIChoice> {
        Binding(
            get: { connection.apiChoice },
            set: { connection.openAIAPI = $0 == .automatic ? nil : $0 }
        )
    }

    public var body: some View {
        Form {
            Section("Identity") {
                TextField("Name", text: $connection.name)
                Toggle("Enabled", isOn: $connection.isEnabled)
            }

            Section("Endpoint") {
                TextField("API Base URL", text: $connection.apiBaseURL)
                    .connectionSettingsField()
                    #if os(iOS)
                    .keyboardType(.URL)
                    #endif
                if connection.usesChatGPTAccount {
                    LabeledContent("Account", value: connection.chatgptEmail ?? "ChatGPT")
                    if connection.chatgptPlanEligible == true {
                        ChatGPTPlanInUseLabel()
                    } else {
                        Text(ChatGPTOAuthCodec.ineligibleUserMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Button("Sign Out", role: .destructive) {
                        onSignOut?()
                    }
                } else {
                    SecureField(connection.apiKeyFieldLabel, text: $connection.apiKey)
                        .connectionSettingsField()
                        .accessibilityIdentifier("connection-api-key")
                    if let footer = connection.apiKeyFieldFooter {
                        Text(footer)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("connection-api-key-footer")
                    }
                }
                if let providerSettings {
                    ServerKindLine(providerSettings: providerSettings, draft: connection)
                } else if let server = connection.detectedServerLabel {
                    LabeledContent("Server", value: server)
                        .accessibilityIdentifier("connection-server-kind")
                }
            }

            if connection.offersAPIChoice {
                Section {
                    Picker("OpenAI API", selection: apiChoiceBinding) {
                        ForEach(OpenAIAPIChoice.allCases) { choice in
                            Text(choice.displayName).tag(choice)
                        }
                    }
                    .accessibilityIdentifier("connection-openai-api")
                } header: {
                    Text("Protocol")
                } footer: {
                    Text(connection.apiChoice.subtitle)
                }
            }

            if let modelDetails, !connection.availableModels.isEmpty {
                Section {
                    Picker("Default model", selection: $connection.defaultModel) {
                        ForEach(connection.availableModels, id: \.self) { model in
                            Text(ModelCapabilityCatalog.displayName(forModelID: model, backend: .remote)).tag(model)
                        }
                    }
                    .accessibilityIdentifier("connection-default-model")
                    ForEach(connection.availableModels, id: \.self) { model in
                        ConnectionModelRows(connection: connection, modelID: model, details: modelDetails)
                    }
                } header: {
                    Text("Models")
                } footer: {
                    Text("Each model keeps its own thinking level. Only the levels a model accepts are listed. A model must pass a one-time tool test before it can be picked for coding.")
                }
            } else {
                Section("Model Options") {
                    Text(modelDetails == nil
                         ? "Thinking and context are set under each model picker in AI Models."
                         : "Query Models on the AI Models page to list this connection's models here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if connection.showsToolFormatPicker {
                Section {
                    Picker("Tool Format", selection: $connection.encoding) {
                        ForEach(RemoteProtocolEncoding.toolFormatPickerCases) { encoding in
                            Text(encoding.displayName).tag(encoding)
                        }
                    }
                    .accessibilityIdentifier("connection-tool-format")
                    if let caption = connection.automaticResolutionCaption() {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("connection-tool-format-resolution")
                    }
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("Automatic uses GPT-OSS (Harmony) for GPT-OSS models and Standard (OpenAI) for every other model.")
                }
            }
        }
        .navigationTitle("Remote Connection")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { onSave(connection) }
            }
        }
    }

}

/// The editor's read-only Server line, from the latest saved answer for the URL being edited.
private struct ServerKindLine: View {
    @ObservedObject var providerSettings: ProviderSettings
    let draft: RemoteConnection

    var body: some View {
        if let server = draft.withServerDetection(from: providerSettings.connection(id: draft.id)).detectedServerLabel {
            LabeledContent("Server", value: server)
                .accessibilityIdentifier("connection-server-kind")
        }
    }
}
