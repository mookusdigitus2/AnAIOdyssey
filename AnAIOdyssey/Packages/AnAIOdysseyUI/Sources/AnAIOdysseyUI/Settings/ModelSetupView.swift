// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import AnAIOdysseyAI
import AnAIOdysseyCore
import AIModelOptions
import SwiftUI

/// First-run overlay.
///
/// On-device AI on supported devices: Apple On-Device stays visible when
/// Apple Intelligence is off or still preparing; it is hidden only when the
/// device is ineligible. MLX appears when Metal plus memory allow it.
/// Continue with ChatGPT runs on Mac (system browser) and on iPhone/iPad
/// (sign-in sheet plus an in-app 127.0.0.1 listener).
struct ModelSetupView: View {
    @ObservedObject var providerSettings: ProviderSettings
    @ObservedObject var chatGPTAccounts: ChatGPTAccountService
    var localModelManager: (any LocalModelManaging)?
    var onFinished: () -> Void

    @State private var localStatuses: [LocalModelStatus] = []
    @State private var downloadingModelID: String?
    @State private var downloadProgress: Double?
    @State private var downloadTask: Task<Void, Never>?
    @State private var rowErrors: [String: String] = [:]
    @State private var errorMessage: String?
    @State private var ineligibleMessage: String?
    @State private var apiKeyDraft: RemoteConnection?

    private var offersLocalMLX: Bool {
        OnDeviceLanguageModelSupport.shouldOfferLocalMLX(manager: localModelManager)
    }

    private var offersAppleFoundation: Bool {
        OnDeviceLanguageModelSupport.shouldOfferAppleFoundation
    }

    private var offersLocalModels: Bool {
        offersLocalMLX || offersAppleFoundation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Choose how \(AppBranding.appName) talks")
                .font(.title2.weight(.semibold))
            Text(introCopy)
                .font(.callout)
                .foregroundStyle(.secondary)

            chatGPTSetupBlock
            addAPIKeyButton
            appleFoundationSetupBlock
            mlxSetupBlock

            if let errorMessage {
                StatusMessage(kind: .error, text: errorMessage)
            }
        }
        .padding(24)
        .frame(maxWidth: 520)
        .onAppear {
            localStatuses = offersLocalMLX ? (localModelManager?.statuses() ?? []) : []
        }
        .chatGPTPlanNotice(chatGPTAccounts)
        .navigationDestination(item: $apiKeyDraft) { draft in
            RemoteConnectionEditorView(
                connection: draft,
                onSave: { updated in
                    providerSettings.updateConnection(updated)
                    apiKeyDraft = nil
                    if providerSettings.adapter(for: updated).isConfigured(connection: updated) {
                        onFinished()
                    }
                },
                onCancel: { apiKeyDraft = nil }
            )
        }
    }

    @ViewBuilder
    private var chatGPTSetupBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            ChatGPTPlanOffer(isBusy: chatGPTAccounts.isSigningIn) {
                Task { await signInWithChatGPT() }
            }
            if let ineligibleMessage {
                StatusMessage(kind: .error, text: ineligibleMessage)
            }
        }
    }

    private var addAPIKeyButton: some View {
        Button("Add API Key") {
            apiKeyDraft = .openAIPreset()
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity, minHeight: 32)
        .accessibilityIdentifier("add-api-key")
    }

    @ViewBuilder
    private var appleFoundationSetupBlock: some View {
        let availability = OnDeviceLanguageModelSupport.appleFoundationAvailability
        if offersAppleFoundation {
            VStack(alignment: .leading, spacing: 8) {
                Text(AppleFoundationModel.displayName)
                    .font(.headline)
                Text(LocalOnDevicePolicy.appleFoundationUserMessage(availability))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(LocalOnDevicePolicy.appleOnDeviceCapabilityNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if availability == .available {
                    Button("Use \(AppleFoundationModel.displayName)") {
                        onFinished()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .accessibilityIdentifier("use-apple-on-device")
                }
            }
        }
    }

    @ViewBuilder
    private var mlxSetupBlock: some View {
        if offersLocalMLX, let localModelManager {
            VStack(alignment: .leading, spacing: 8) {
                Text("Local models")
                    .font(.headline)
                Text("On-device AI on this supported device. Download one to use it without a remote provider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(ModelCatalogService.memorySummaryText())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(localStatuses) { status in
                    setupLocalRow(status, manager: localModelManager)
                }
            }
        }
    }

    private var introCopy: String {
        if offersLocalModels {
            return "Continue with ChatGPT, add an API key, or use on-device AI on this supported device."
        }
        return "This device uses your chosen AI provider. Continue with ChatGPT or add an API key."
    }

    @ViewBuilder
    private func setupLocalRow(_ status: LocalModelStatus, manager: any LocalModelManaging) -> some View {
        let presentation = LocalModelDownloadPolicy.present(
            LocalModelRowInput(
                catalogID: status.id,
                displayName: status.option.displayName,
                manifestSizeText: LocalModelDownloadPolicy.manifest(forCatalogID: status.id)?.sizeText
                    ?? String(format: "%.1f GB", status.option.estimatedMemoryGB),
                completeness: status.completeness,
                isDownloading: downloadingModelID == status.id,
                downloadProgress: downloadingModelID == status.id ? downloadProgress : nil,
                errorMessage: rowErrors[status.id]
            )
        )
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(status.option.displayName)
                HStack(spacing: 6) {
                    if presentation.showsLoadedCheckmark {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .accessibilityHidden(true)
                    }
                    if presentation.showsProgress {
                        ProgressView(value: presentation.progress)
                            .frame(maxWidth: 88)
                    }
                    Text(presentation.statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !status.fitsMemoryBudget {
                Text("Unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let action = presentation.action, action != .delete {
                Button(action.title) {
                    handleSetupAction(action, status: status, manager: manager)
                }
                .isolatedFormButton()
                .disabled(downloadingModelID != nil && action != .cancel)
                .accessibilityIdentifier("local-model-\(action.rawValue)-\(status.id)")
            }
        }
    }

    private func handleSetupAction(
        _ action: LocalModelRowAction,
        status: LocalModelStatus,
        manager: any LocalModelManaging
    ) {
        switch action {
        case .download:
            startDownload(status.id, manager: manager, wipeFirst: false)
        case .downloadAgain, .tryAgain:
            startDownload(status.id, manager: manager, wipeFirst: true)
        case .cancel:
            cancelDownload(status.id, manager: manager)
        case .delete:
            break
        }
    }

    private func signInWithChatGPT() async {
        errorMessage = nil
        ineligibleMessage = nil
        do {
            try await chatGPTAccounts.signIn(into: providerSettings)
            // Keep the sheet up while the one-time plan notice is showing.
            if !chatGPTAccounts.showsPlanNotice {
                onFinished()
            }
        } catch ChatGPTAccountError.ineligible {
            ineligibleMessage = ChatGPTOAuthCodec.ineligibleUserMessage
        } catch ChatGPTAccountError.cancelled {
            // User closed the sign-in sheet.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startDownload(_ modelID: String, manager: any LocalModelManaging, wipeFirst: Bool) {
        downloadTask?.cancel()
        downloadTask = Task {
            await download(modelID, manager: manager, wipeFirst: wipeFirst)
        }
    }

    private func cancelDownload(_ modelID: String, manager: any LocalModelManaging) {
        downloadTask?.cancel()
        downloadTask = nil
        downloadingModelID = nil
        downloadProgress = nil
        rowErrors[modelID] = nil
        do {
            try manager.discardPartialDownload(modelID)
        } catch {
            rowErrors[modelID] = error.localizedDescription
        }
        localStatuses = manager.statuses()
    }

    private func download(_ modelID: String, manager: any LocalModelManaging, wipeFirst: Bool) async {
        downloadingModelID = modelID
        downloadProgress = 0
        rowErrors[modelID] = nil
        defer {
            if downloadingModelID == modelID {
                downloadingModelID = nil
                downloadProgress = nil
            }
            localStatuses = manager.statuses()
        }
        do {
            if wipeFirst {
                try manager.discardPartialDownload(modelID)
            }
            try await manager.download(modelID) { progress in
                downloadProgress = progress
            }
            onFinished()
        } catch is CancellationError {
            try? manager.discardPartialDownload(modelID)
        } catch {
            rowErrors[modelID] = error.localizedDescription
        }
    }
}

struct FirstRunModelSetupModifier: ViewModifier {
    @EnvironmentObject private var providerSettings: ProviderSettings
    @EnvironmentObject private var chatGPTAccounts: ChatGPTAccountService
    @Environment(\.localModelManager) private var localModelManager
    @AppStorage("anaiodyssey.setup.completed") private var setupCompleted = false
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .onAppear(perform: evaluate)
            .onChange(of: providerSettings.remoteConnections) { _, _ in evaluate() }
            .sheet(isPresented: $isPresented) {
                NavigationStack {
                    ModelSetupView(
                        providerSettings: providerSettings,
                        chatGPTAccounts: chatGPTAccounts,
                        localModelManager: localModelManager,
                        onFinished: complete
                    )
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Not now", action: complete)
                        }
                    }
                }
            }
    }

    private func complete() {
        setupCompleted = true
        isPresented = false
    }

    private func evaluate() {
        if setupCompleted {
            isPresented = false
            return
        }
        if providerSettings.isRemoteConfigured {
            isPresented = false
            return
        }
        if OnDeviceLanguageModelSupport.appleFoundationIsReady {
            isPresented = false
            return
        }
        if OnDeviceLanguageModelSupport.shouldOfferLocalMLX(manager: localModelManager),
           let manager = localModelManager,
           manager.statuses().contains(where: \.isDownloaded) {
            isPresented = false
            return
        }
        isPresented = true
    }
}

extension View {
    func firstRunModelSetup() -> some View {
        modifier(FirstRunModelSetupModifier())
    }
}
