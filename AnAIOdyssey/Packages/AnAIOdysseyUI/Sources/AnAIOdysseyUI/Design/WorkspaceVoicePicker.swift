// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import AnAIOdysseyAI
import AIModelOptions
import SwiftUI

/// Two-row spoken-reply picker used in Settings and Chat: Voice Provider, then Voice.
///
/// Providers without a working key are omitted. Voices show friendly names only
/// ("Ara", "Alloy") with a play/stop preview that uses a provider sample URL or a
/// cached synthesis of a fixed phrase.
struct WorkspaceVoicePicker: View {
    @ObservedObject var agentRegistrySettings: AgentRegistrySettings
    @ObservedObject var providerSettings: ProviderSettings
    var showsCredentialFields = false
    @ObservedObject private var previewService = VoicePreviewService.shared
    /// Page state lives in one long-lived reference model, not @State or
    /// @StateObject. The voice list is a NavigationLink destination closure
    /// that captured a copy of this view; reading @State/@StateObject from
    /// that copy outside its body hits detached storage (a fresh object each
    /// access), so lookup events, Save/Cancel enablement and the draft never
    /// reached the screen on build 15. A shared object is the same instance
    /// from any copy, like VoicePreviewService.shared.
    @ObservedObject private var ui = VoicePickerModel.shared
    /// Lookup/add run in VoiceLibraryService (outside the view); this view only
    /// renders its events and sends intents.
    private let addWorker = VoiceLibraryService.shared
    #if os(macOS)
    @State private var isVoiceListPresented = false
    #endif

    private var availableProviders: [VoiceProvider] {
        VoiceCatalog.availableProviders(
            elevenLabsKeyConfigured: !agentRegistrySettings.elevenLabsAPIKey
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            openAIKeyConfigured: providerSettings.hasConfiguredOpenAITTSKey,
            xaiKeyConfigured: providerSettings.hasConfiguredXAITTSKey
        )
    }

    private var selectedProvider: VoiceProvider {
        VoiceCatalog.resolvedProvider(
            agentRegistrySettings.voiceProvider,
            available: availableProviders
        )
    }

    private var elevenLabsSections: (added: [VoiceOption], catalog: [VoiceOption]) {
        VoiceCatalog.elevenLabsPickerSections(
            fetched: ui.elevenLabsVoices,
            added: agentRegistrySettings.elevenLabsAddedVoices.map(\.voiceOption),
            currentID: agentRegistrySettings.elevenLabsVoiceID
        )
    }

    private var voices: [VoiceOption] {
        switch selectedProvider {
        case .system:
            return ui.systemVoices.isEmpty ? VoiceCatalog.voices(for: .system) : ui.systemVoices
        case .elevenLabs:
            let sections = elevenLabsSections
            return sections.added + sections.catalog
        case .openai:
            return VoiceCatalog.voices(for: .openai, modelID: VoiceCatalog.defaultOpenAIModelID)
        case .xai:
            return VoiceCatalog.mergeVoiceLists(ui.xaiVoices, fallingBackTo: VoiceCatalog.xaiVoices)
        case .appleIntelligence:
            return []
        }
    }

    private var selectedVoice: VoiceOption? {
        let currentID = agentRegistrySettings.voiceID(for: selectedProvider)
        if selectedProvider == .elevenLabs {
            return VoiceCatalog.selectedVoice(currentID: currentID, from: voices)
        }
        return voices.first(where: { $0.id == currentID }) ?? voices.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            formRows
        }
    }

    /// Separate Form rows for Settings. Call this from a Section/`@ViewBuilder`,
    /// not from a wrapping `View`, so Provider and Voice are not one tappable cell.
    @ViewBuilder
    var formRows: some View {
            LabeledContent("Voice Provider") {
                Picker("Voice Provider", selection: $agentRegistrySettings.voiceProvider) {
                    ForEach(availableProviders) { provider in
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                }
                .labelsHidden()
                #if os(macOS)
                .pickerStyle(.menu)
                .frame(minWidth: 160, maxWidth: 240)
                #endif
                .accessibilityIdentifier("spoken-reply-provider-picker")
            }
            .onAppear {
                snapInvalidSelections()
                ui.systemVoices = SystemVoiceCatalog.voices()
                Task { await refreshRemoteVoices() }
            }
            .onChange(of: agentRegistrySettings.voiceProvider) { _, _ in
                snapInvalidSelections()
                previewService.stop()
            }
            .onChange(of: agentRegistrySettings.elevenLabsAPIKey) { _, _ in
                snapInvalidSelections()
                Task { await refreshRemoteVoices() }
            }
            .onChange(of: providerSettings.remoteConnections) { _, _ in
                snapInvalidSelections()
                Task { await refreshRemoteVoices() }
            }
            .onDisappear { stopBackgroundWork() }

            #if os(iOS)
            NavigationLink {
                VoicePickerPage(ui: ui, settings: agentRegistrySettings, preview: previewService) { voiceList }
                    .navigationTitle("Voice")
                    .navigationBarTitleDisplayMode(.inline)
                    .onDisappear { stopBackgroundWork() }
            } label: {
                LabeledContent("Voice", value: selectedVoice?.displayName ?? "Voice")
            }
            .accessibilityIdentifier("spoken-reply-voice-picker")
            #else
            LabeledContent("Voice") {
                Button {
                    isVoiceListPresented = true
                } label: {
                    Text(selectedVoice?.displayName ?? "Voice")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .isolatedFormButton()
                .accessibilityIdentifier("spoken-reply-voice-picker")
                .popover(isPresented: $isVoiceListPresented) {
                    VoicePickerPage(ui: ui, settings: agentRegistrySettings, preview: previewService) { voiceList }
                        .frame(minWidth: 260, minHeight: 200)
                        .onDisappear { stopBackgroundWork() }
                }
            }
            #endif

            if showsCredentialFields {
                SecureField("ElevenLabs API Key", text: $agentRegistrySettings.elevenLabsAPIKey)
                    .workspaceSettingsField()
                    .accessibilityIdentifier("elevenlabs-api-key")
            }
    }

    private var voiceList: some View {
        voiceListContent
            .task {
                // Subscription is tied to this view; dismissing cancels it
                // (unsubscribe) while the service keeps any add going.
                for await event in await addWorker.events() {
                    apply(event)
                }
            }
            .confirmationDialog(
                "Remove \(ui.pendingRemoval?.displayName ?? "voice")?",
                isPresented: Binding(get: { ui.pendingRemoval != nil }, set: { if !$0 { ui.pendingRemoval = nil } }),
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    if let id = ui.pendingRemoval?.id { removeAddedVoice(id: id) }
                    ui.pendingRemoval = nil
                }
            } message: {
                Text("It's your current voice. Replies will switch to \(removalReplacementName).")
            }
    }

    private var voiceListContent: some View {
        List {
            if selectedProvider == .elevenLabs {
                elevenLabsVoiceSections
            } else {
                ForEach(voices) { voice in
                    voiceRow(voice)
                }
            }
        }
        #if os(macOS)
        .listStyle(.inset)
        #endif
    }

    @ViewBuilder
    private var elevenLabsVoiceSections: some View {
        let sections = elevenLabsSections
        if !sections.added.isEmpty {
            Section("Added Voices") {
                ForEach(sections.added) { voice in
                    voiceRow(voice)
                        .contextMenu {
                            Button("Remove", role: .destructive) {
                                requestRemoveAddedVoice(id: voice.id)
                            }
                        }
                }
                .onDelete { offsets in
                    let ids = offsets.map { sections.added[$0].id }
                    for id in ids {
                        requestRemoveAddedVoice(id: id)
                    }
                }
            }
        }
        Section {
            ForEach(sections.catalog) { voice in
                voiceRow(voice)
            }
        }
        Section {
            addVoiceByIDRow
        } header: {
            Text("Add Voice")
        } footer: {
            Text(VoiceAddDraft.footer)
        }
        if let status = ui.elevenLabsStatus ?? previewService.lastError, !status.isEmpty {
            Section {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("elevenlabs-voice-status")
            }
        }
    }

    private var addVoiceByIDRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Voice ID", text: $ui.addDraft.voiceID)
                    .workspaceSettingsField()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .accessibilityIdentifier("voice-add-by-id-field")
                    .onChange(of: ui.addDraft.voiceID) { _, newValue in
                        ui.addDraft.voiceIDChanged()
                        let key = agentRegistrySettings.elevenLabsAPIKey
                        ui.lookupSequence += 1
                    let sequence = ui.lookupSequence
                    Task { await addWorker.lookup(voiceID: newValue, apiKey: key, sequence: sequence) }
                    }
                    .onSubmit { saveDraftVoice() }
                if case .loading = ui.voiceLookup {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Looking up…")
                        .accessibilityIdentifier("voice-add-lookup-spinner")
                }
            }
            lookupStatusRow
            if ui.addDraft.canSave {
                HStack(spacing: 8) {
                    TextField("Name", text: $ui.addDraft.name)
                        .workspaceSettingsField()
                        .submitLabel(.done)
                        .accessibilityIdentifier("voice-add-name-field")
                        .onSubmit { saveDraftVoice() }
                    if let record = ui.addDraft.recordToSave {
                        previewButton(for: record.voiceOption)
                    }
                }
            }
            if let error = ui.addDraft.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("voice-add-error")
            }
            HStack {
                // Always enabled: discards only the uncommitted draft, lookup and
                // preview. A voice already saved keeps adding in the background.
                Button("Cancel", role: .cancel) {
                    previewService.stop()
                    ui.addDraft.reset()
                    Task { await addWorker.cancelLookup() }
                }
                .isolatedFormButton()
                .accessibilityIdentifier("voice-add-cancel-button")
                Spacer()
                if ui.isAddingVoice { ProgressView().controlSize(.small) }
                Button("Save") { saveDraftVoice() }
                    .isolatedFormButton()
                    .buttonStyle(.borderedProminent)
                    .disabled(!ui.addDraft.canSave)
                    .accessibilityIdentifier("voice-add-save-button")
            }
        }
    }

    @ViewBuilder
    private var lookupStatusRow: some View {
        switch ui.voiceLookup {
        case .idle:
            let typed = ui.addDraft.voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !typed.isEmpty, typed.count < 12 {
                Text("Keep typing: ElevenLabs voice IDs are about 20 characters. Save turns on once the voice is found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("voice-add-hint")
            }
        case .found:
            EmptyView()
        case .loading:
            Text("Looking up…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("voice-add-looking-up")
        case .notFound:
            Text(ElevenLabsVoiceErrors.notFoundMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func saveDraftVoice() {
        guard ui.addDraft.canSave, !ui.isAddingVoice, let record = ui.addDraft.recordToSave else { return }
        let isLibrary = ui.addDraft.isLibrary
        let key = agentRegistrySettings.elevenLabsAPIKey
        let settings = agentRegistrySettings
        Task {
            await addWorker.add(record, isLibrary: isLibrary, apiKey: key) { saved in
                // Runs even if this view is gone; settings outlive it.
                settings.addElevenLabsVoice(saved)
                settings.voiceProvider = VoiceProvider.elevenLabs.rawValue
            }
        }
    }

    /// Applies a worker event. Only called from this view's own subscription,
    /// which ends when the view disappears.
    private func apply(_ event: VoiceAddEvent) {
        ui.isAddingVoice = event == .adding
        switch event {
        case .idle: ui.voiceLookup = .idle
        case .lookingUp: ui.voiceLookup = .loading
        case .found(let record, let isLibrary):
            guard ui.addDraft.voiceID.trimmingCharacters(in: .whitespacesAndNewlines) == record.voiceID else { return }
            ui.voiceLookup = .found(record, isLibrary: isLibrary)
            ui.addDraft.lookupSucceeded(record, isLibrary: isLibrary)
            if ElevenLabsVoiceErrors.isPaidPlanRestriction(freeUsersAllowed: record.freeUsersAllowed) {
                ui.elevenLabsStatus = ElevenLabsVoiceErrors.paidPlanMessage
            }
        case .notFound: ui.voiceLookup = .notFound
        case .adding: ui.addDraft.error = nil
        case .added:
            ui.addDraft.reset()
            ui.voiceLookup = .idle
            Task { await refreshRemoteVoices() }
        case .failed(let message):
            if case .loading = ui.voiceLookup { ui.voiceLookup = .failed(message) } else { ui.addDraft.error = message }
        }
    }

    private func voiceRow(_ voice: VoiceOption) -> some View {
        HStack(spacing: 8) {
            Button {
                agentRegistrySettings.setVoiceID(voice.id, for: selectedProvider)
            } label: {
                HStack {
                    Text(voice.displayName)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    if voice.id == selectedVoice?.id {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                    }
                }
            }
            .isolatedFormButton()
            .accessibilityLabel(voice.displayName)

            previewButton(for: voice)
        }
    }

    private func previewButton(for voice: VoiceOption) -> some View {
        let key = VoiceCatalog.previewCacheKey(provider: selectedProvider, voiceID: voice.id)
        return Button {
            Task {
                await previewService.toggle(
                    provider: selectedProvider,
                    voice: voice,
                    apiKey: previewAPIKey,
                    baseURL: previewBaseURL
                )
            }
        } label: {
            if previewService.isLoading(cacheKey: key) {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: previewService.isPlaying(cacheKey: key) ? "stop.fill" : "play.fill")
            }
        }
        .isolatedFormButton()
        .accessibilityLabel(
            previewService.isPlaying(cacheKey: key)
                ? "Stop preview of \(voice.displayName)"
                : "Preview \(voice.displayName)"
        )
        .accessibilityIdentifier("voice-preview-\(voice.id)")
        .disabled(previewService.isLoading(cacheKey: key) && !previewService.isPlaying(cacheKey: key))
    }

    private var previewAPIKey: String {
        switch selectedProvider {
        case .elevenLabs:
            return agentRegistrySettings.elevenLabsAPIKey
        case .openai:
            return providerSettings.openAITTSConnection()?.apiKey ?? ""
        case .xai:
            return providerSettings.xAITTSConnection()?.apiKey ?? ""
        case .system, .appleIntelligence:
            return ""
        }
    }

    private var previewBaseURL: String? {
        switch selectedProvider {
        case .openai:
            return providerSettings.openAITTSConnection()?.trimmedBaseURL
        default:
            return nil
        }
    }

    private func snapInvalidSelections() {
        let resolved = VoiceCatalog.resolvedProvider(
            agentRegistrySettings.voiceProvider,
            available: availableProviders
        )
        if agentRegistrySettings.voiceProvider != resolved.rawValue {
            VoiceAudioDebugStore.append(
                event: "picker.snap.provider",
                detail: "\(agentRegistrySettings.voiceProvider) -> \(resolved.rawValue)"
            )
            agentRegistrySettings.voiceProvider = resolved.rawValue
        }
        let current = agentRegistrySettings.voiceID(for: resolved)
        let options = voicesForSnap(resolved)
        if options.contains(where: { $0.id == current }) { return }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        if let first = options.first {
            VoiceAudioDebugStore.append(event: "picker.snap.voice", detail: "\(resolved.rawValue) '' -> \(first.id)")
            agentRegistrySettings.setVoiceID(first.id, for: resolved)
        }
    }

    private func voicesForSnap(_ provider: VoiceProvider) -> [VoiceOption] {
        switch provider {
        case .system: return ui.systemVoices.isEmpty ? VoiceCatalog.voices(for: .system) : ui.systemVoices
        case .elevenLabs:
            let sections = elevenLabsSections
            return sections.added + sections.catalog
        case .openai: return VoiceCatalog.voices(for: .openai)
        case .xai: return VoiceCatalog.mergeVoiceLists(ui.xaiVoices, fallingBackTo: VoiceCatalog.xaiVoices)
        case .appleIntelligence: return []
        }
    }

    private func refreshRemoteVoices() async {
        if let key = nonEmpty(agentRegistrySettings.elevenLabsAPIKey) {
            do {
                let fetched = try await ElevenLabsVoiceService.listVoices(apiKey: key)
                if !fetched.isEmpty {
                    ui.elevenLabsVoices = fetched.map { option in
                        VoiceOption(
                            id: option.id,
                            displayName: Self.friendlyDisplayName(option.displayName, fallbackID: option.id),
                            previewURL: option.previewURL
                        )
                    }
                }
                ui.elevenLabsStatus = nil
            } catch {
                ui.elevenLabsStatus = (error as? LocalizedError)?.errorDescription
                    ?? ElevenLabsVoiceErrors.listFailedMessage
            }
        }
        if let connection = providerSettings.xAITTSConnection() {
            if let fetched = try? await XAIVoiceService.listVoices(apiKey: connection.apiKey), !fetched.isEmpty {
                ui.xaiVoices = fetched.map { option in
                    VoiceOption(
                        id: option.id,
                        displayName: Self.friendlyDisplayName(option.displayName, fallbackID: option.id),
                        previewURL: option.previewURL
                    )
                }
            }
        }
    }

    /// Drops provider/model ids from labels so the list stays "Ara", "Alloy".
    static func friendlyDisplayName(_ name: String, fallbackID: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return VoiceCatalog.friendlyName(fromID: fallbackID) }
        if trimmed.contains("gpt-") || trimmed.contains("tts-") || trimmed.contains("eleven_") {
            return VoiceCatalog.friendlyName(fromID: fallbackID)
        }
        return trimmed
    }

    private func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    enum VoiceLookupState: Equatable {
        case idle
        case loading
        case found(ElevenLabsVoiceRecord, isLibrary: Bool)
        case notFound
        case failed(String)
    }

    /// Stops preview playback when the picker goes away. Lookup/add live in
    /// VoiceLibraryService and are not tied to this view.
    private func stopBackgroundWork() {
        // Back/Done: cancel only what isn't committed (lookup, preview).
        // Never awaits anything, so dismissal is immediate.
        previewService.stop()
        Task { await addWorker.cancelLookup() }
    }

    /// Confirms first when the voice being removed is the active one.
    private func requestRemoveAddedVoice(id: String) {
        let sections = elevenLabsSections
        if VoiceRemovalPlan.replacement(removing: id, active: agentRegistrySettings.elevenLabsVoiceID,
                                        added: sections.added, catalog: sections.catalog) != nil,
           let voice = sections.added.first(where: { $0.id == id }) {
            ui.pendingRemoval = voice
        } else {
            removeAddedVoice(id: id)
        }
    }

    private func removeAddedVoice(id: String) {
        let sections = elevenLabsSections
        let replacement = VoiceRemovalPlan.replacement(removing: id, active: agentRegistrySettings.elevenLabsVoiceID,
                                                       added: sections.added, catalog: sections.catalog)
        agentRegistrySettings.removeElevenLabsAddedVoice(id: id)
        if let replacement {
            agentRegistrySettings.setVoiceID(replacement.id, for: .elevenLabs)
        }
    }

    private var removalReplacementName: String {
        guard let pendingRemoval = ui.pendingRemoval else { return "" }
        let sections = elevenLabsSections
        return VoiceRemovalPlan.replacement(removing: pendingRemoval.id, active: pendingRemoval.id,
                                            added: sections.added, catalog: sections.catalog)?.displayName ?? "the default voice"
    }
}


@MainActor
final class VoicePickerModel: ObservableObject {
    static let shared = VoicePickerModel()
    @Published var elevenLabsVoices: [VoiceOption] = VoiceCatalog.elevenLabsVoices
    @Published var xaiVoices: [VoiceOption] = VoiceCatalog.xaiVoices
    @Published var systemVoices: [VoiceOption] = SystemVoiceCatalog.voices()
    @Published var elevenLabsStatus: String?
    @Published var voiceLookup: WorkspaceVoicePicker.VoiceLookupState = .idle
    @Published var addDraft = VoiceAddDraft()
    @Published var isAddingVoice = false
    @Published var pendingRemoval: VoiceOption?
    /// Monotonic across picker instances (the service is shared).
    var lookupSequence: Int {
        get { Self.sequence }
        set { Self.sequence = newValue }
    }
    private static var sequence = 0
}

/// Observes the picker's reference state so the pushed page re-renders on
/// every change (the content closure reads through the shared model).
private struct VoicePickerPage<Content: View>: View {
    @ObservedObject var ui: VoicePickerModel
    @ObservedObject var settings: AgentRegistrySettings
    @ObservedObject var preview: VoicePreviewService
    @ViewBuilder var content: () -> Content
    var body: some View { content() }
}
