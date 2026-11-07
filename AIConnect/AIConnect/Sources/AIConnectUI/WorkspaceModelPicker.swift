// SPDX-License-Identifier: MIT
import AIConnect
import AIModelOptions
import SwiftUI

/// Unified model dropdown for chat, research, and compare surfaces.
///
/// Lists the models available for the current provider settings and writes the
/// chosen `selectionKey` back to the caller. It self-heals: if the bound key ever
/// points at a model that disappears (provider change, refreshed model list), it
/// snaps to the first valid choice so the picker never shows a stale/empty value.
public struct WorkspaceModelPicker: View {
    /// Picker label (hidden visually but used for accessibility).
    let label: String
    /// The selected model's encoded key, owned by the caller.
    @Binding var selectionKey: String
    /// Provider configuration that determines which models are offered.
    let providerSettings: ProviderSettings
    /// Optional accessibility identifier override.
    var accessibilityIdentifier: String?
    /// Chat/research pickers show the 10 newest chat models; Compare uses `.unfiltered`.
    var pickerScope: ConfiguredModelRegistry.PickerScope = .chatRecent

    /// On-device model manager, used to hide local models that aren't installed.
    @Environment(\.localModelManager) private var localModelManager

    /// Optional precomputed downloaded-model ids from a parent that already
    /// scanned disk (Settings). When nil, this picker scans once and caches.
    var downloadedLocalModelIDs: Set<String>? = nil

    /// Cached picker rows. `statuses()` walks the model cache on disk, so this
    /// must not be recomputed from `body` while a Form scrolls.
    @State private var cachedChoices: [ConfiguredModelChoice] = []

    /// Public so other apps can show the same chat model picker.
    public init(
        label: String,
        selectionKey: Binding<String>,
        providerSettings: ProviderSettings,
        accessibilityIdentifier: String? = nil,
        pickerScope: ConfiguredModelRegistry.PickerScope = .chatRecent,
        downloadedLocalModelIDs: Set<String>? = nil
    ) {
        self.label = label
        self._selectionKey = selectionKey
        self.providerSettings = providerSettings
        self.accessibilityIdentifier = accessibilityIdentifier
        self.pickerScope = pickerScope
        self.downloadedLocalModelIDs = downloadedLocalModelIDs
    }

    public var body: some View {
        Picker(label, selection: $selectionKey) {
            ForEach(cachedChoices, id: \.selectionKey) { choice in
                Text(choice.pickerLabel).tag(choice.selectionKey)
            }
        }
        .labelsHidden()
        #if os(macOS)
        .pickerStyle(.menu)
        .frame(minWidth: 220, maxWidth: 360)
        #endif
        .accessibilityIdentifier(accessibilityIdentifier ?? "workspace-model-picker")
        // Load once, then again only when the remote catalog or parent disk scan changes.
        .onAppear(perform: refreshChoicesAndSelection)
        .onChange(of: providerSettings.remoteConnections) { _, _ in refreshChoicesAndSelection() }
        .onChange(of: downloadedLocalModelIDs) { _, _ in refreshChoicesAndSelection() }
    }

    /// Rebuilds the cached choice list and snaps an invalid selection to the first row.
    ///
    /// A selection that the registry still recognizes (for example a stored local
    /// model that isn't downloaded) is prepended instead of written over. Writing
    /// here would persist a Settings override the user never chose.
    private func refreshChoicesAndSelection() {
        let offerLocal = OnDeviceLanguageModelSupport.shouldOfferLocalMLX(manager: localModelManager)
        let offerApple = OnDeviceLanguageModelSupport.shouldOfferAppleFoundation
        let choices = ConfiguredModelRegistry.pickerChoices(
            providerSettings: providerSettings,
            downloadedLocalModelIDs: resolvedDownloadedLocalModelIDs(),
            scope: pickerScope,
            selectionKey: selectionKey,
            offerLocalMLX: offerLocal,
            offerAppleFoundation: offerApple
        )
        cachedChoices = choices
        let resolved = ConfiguredModelRegistry.resolvedPickerSelection(
            stored: selectionKey,
            choices: choices
        )
        if resolved != selectionKey {
            selectionKey = resolved
        }
    }

    /// Parent-provided ids, or a one-off disk scan when the parent didn't supply any.
    private func resolvedDownloadedLocalModelIDs() -> Set<String> {
        if let downloadedLocalModelIDs {
            return downloadedLocalModelIDs
        }
        guard OnDeviceLanguageModelSupport.shouldOfferLocalMLX(manager: localModelManager),
              let localModelManager else { return [] }
        return Set(localModelManager.statuses().filter(\.isDownloaded).map(\.option.id))
    }
}

/// Settings rows: labeled model picker, Options, and Reset as separate Form rows.
///
/// Must be a `@ViewBuilder` (not a wrapping `View`) so Form flattens the children.
/// A `VStack`/`View` would put Picker + Options + Reset in one row, and iOS would
/// fire Reset on the same tap as a model choice.
@ViewBuilder
public func FeatureDefaultModelPickerRows(
    title: String,
    selectionKey: Binding<String>,
    providerSettings: ProviderSettings,
    accessibilityIdentifier: String,
    downloadedLocalModelIDs: Set<String>? = nil,
    onReset: (() -> Void)? = nil,
    resetLabel: String = "Use Global Default",
    resetDisabled: Bool = false,
    optionsStyle: ModelPickerOptionsStyle = .collapsed,
    inheritsGlobalOptions: Bool = false,
    pickerScope: ConfiguredModelRegistry.PickerScope = .chatRecent
) -> some View {
    LabeledContent(title) {
        WorkspaceModelPicker(
            label: title,
            selectionKey: selectionKey,
            providerSettings: providerSettings,
            accessibilityIdentifier: accessibilityIdentifier,
            pickerScope: pickerScope,
            downloadedLocalModelIDs: downloadedLocalModelIDs
        )
    }
    ModelPickerOptionsView(
        selectionKey: selectionKey.wrappedValue,
        style: optionsStyle,
        isEditable: ModelOptionsFormatting.shouldShowEditableOptions(
            hasOwnModelSelection: !inheritsGlobalOptions
        )
    )
    if let onReset {
        Button(resetLabel, action: onReset)
            .connectionFormButton()
            .font(.caption)
            .disabled(resetDisabled)
    }
}

/// Which settings default the pushed model list edits.
public enum SettingsModelPickerRoute: Hashable {
    case global
    case feature(WorkspaceFeature)
}

#if os(iOS)
/// Full model list, pushed from AI Models settings.
///
/// The scrolling form only shows the current choice. Building every option inside
/// each `Picker` stalled the form as those rows scrolled on screen.
public struct SettingsModelChoiceList: View {
    let title: String
    @Binding var selectionKey: String
    let choices: [ConfiguredModelChoice]
    var resetLabel: String
    var resetDisabled: Bool
    var onReset: () -> Void

    public init(
        title: String,
        selectionKey: Binding<String>,
        choices: [ConfiguredModelChoice],
        resetLabel: String,
        resetDisabled: Bool,
        onReset: @escaping () -> Void
    ) {
        self.title = title
        self._selectionKey = selectionKey
        self.choices = choices
        self.resetLabel = resetLabel
        self.resetDisabled = resetDisabled
        self.onReset = onReset
    }

    public var body: some View {
        List {
            if choices.isEmpty {
                Text("No models are available. Download a local model or add a remote connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(choices, id: \.selectionKey) { choice in
                    Button {
                        selectionKey = choice.selectionKey
                    } label: {
                        HStack {
                            Text(choice.pickerLabel)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 12)
                            if choice.selectionKey == selectionKey {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .connectionFormButton()
                    .accessibilityIdentifier("model-choice-\(choice.id)")
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button(resetLabel, action: onReset)
                    .disabled(resetDisabled)
            }
        }
    }
}
#endif
