// SPDX-License-Identifier: MIT
import AIConnect
import AIModelOptions
import SwiftUI

/// How thinking/context controls appear under a model picker.
public enum ModelPickerOptionsStyle: Equatable {
    /// Toolbar pickers stay compact.
    case hidden
    /// Global default in Settings: always visible.
    case expanded
    /// Per-feature Settings pickers: behind a disclosure.
    case collapsed
}

/// Per-model Options: thinking, context, max output, and remember-thinking.
///
/// Lookups are catalog + UserDefaults keyed by `selectionKey`. Nothing here
/// walks the model cache or rebuilds `availableChoices`.
public struct ModelPickerOptionsView: View {
    public let selectionKey: String
    public var style: ModelPickerOptionsStyle = .collapsed
    /// Per-tab rows that still use the global model are read-only.
    public var isEditable: Bool = true

    public init(selectionKey: String, style: ModelPickerOptionsStyle = .collapsed, isEditable: Bool = true) {
        self.selectionKey = selectionKey
        self.style = style
        self.isEditable = isEditable
    }

    @State private var effort: ReasoningEffort = .medium
    @State private var contextTokens: Int? = nil
    @State private var maxOutputTokens: Int? = nil
    @State private var rememberThinking = true
    @State private var isLoading = false
    @State private var optionsEpoch = 0

    public var body: some View {
        Group {
            if style != .hidden, parsed != nil, parsed?.backend != .auto {
                optionsContainer
            }
        }
        .onAppear(perform: loadOptions)
        .onChange(of: selectionKey) { _, _ in loadOptions() }
        .onChange(of: isEditable) { _, _ in loadOptions() }
        .onChange(of: effort) { _, _ in saveOptions() }
        .onChange(of: contextTokens) { _, _ in saveOptions() }
        .onChange(of: maxOutputTokens) { _, _ in saveOptions() }
        .onChange(of: rememberThinking) { _, _ in saveOptions() }
        .onReceive(NotificationCenter.default.publisher(for: ModelGenerationSettings.didChangeNotification)) { _ in
            optionsEpoch += 1
            if !isEditable {
                loadOptions()
            }
        }
    }

    @ViewBuilder
    private var optionsContainer: some View {
        if !isEditable {
            Text(inheritedLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("model-options-inherited")
        } else {
            switch style {
            case .hidden:
                EmptyView()
            case .expanded:
                optionsControls
            case .collapsed:
                DisclosureGroup("Options") {
                    optionsControls
                }
                .font(.subheadline)
            }
        }
    }

    private var optionsControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if capabilities.supportsThinking {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Thinking", selection: $effort) {
                        ForEach(capabilities.supportedReasoningEfforts) { level in
                            Text(
                                ModelOptionsFormatting.thinkingPickerLabel(
                                    level,
                                    defaultEffort: capabilities.defaultReasoningEffort
                                )
                            ).tag(level)
                        }
                    }
                    .accessibilityIdentifier("model-options-thinking")
                    Text("Higher levels think longer and cost more per reply.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Picker("Context", selection: $contextTokens) {
                    Text("Auto").tag(Optional<Int>.none)
                    ForEach(contextChoices, id: \.self) { size in
                        Text(ModelCapabilityCatalog.contextLabel(tokens: size)).tag(Optional(size))
                    }
                }
                .accessibilityIdentifier("model-options-context")
                Text("Larger context remembers more of the conversation but uses more tokens.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Picker("Max output", selection: $maxOutputTokens) {
                    Text("Auto").tag(Optional<Int>.none)
                    ForEach(maxOutputChoices, id: \.self) { size in
                        Text(ModelCapabilityCatalog.contextLabel(tokens: size)).tag(Optional(size))
                    }
                }
                .accessibilityIdentifier("model-options-max-output")
            }

            if capabilities.supportsRememberThinking {
                Toggle("Remember thinking across turns", isOn: $rememberThinking)
                    .accessibilityIdentifier("model-options-remember-thinking")
            }
        }
        .padding(.top, 2)
    }

    private var parsed: ParsedModelSelection? {
        ConfiguredModelRegistry.parseSelectionKey(selectionKey)
    }

    private var capabilities: ModelCapabilities {
        guard let parsed else {
            return ModelCapabilityCatalog.capabilities(forModelID: "", backend: .remote)
        }
        let backend: ModelBackendKind
        switch parsed.backend {
        case .localMLX: backend = .localMLX
        case .appleFoundation: backend = .appleFoundation
        case .remote, .auto: backend = .remote
        }
        let live: LiveModelCapabilities?
        if let connectionID = parsed.connectionID {
            live = ProviderSettings.shared.connection(id: connectionID)?.liveCapabilities(for: parsed.modelID)
        } else {
            live = nil
        }
        return ModelCapabilityCatalog.capabilities(forModelID: parsed.modelID, backend: backend, live: live)
    }

    private var contextChoices: [Int] {
        ModelCapabilityCatalog.contextChoices(for: capabilities)
    }

    private var maxOutputChoices: [Int] {
        ModelOptionsFormatting.maxOutputChoices(for: capabilities)
    }

    private var inheritedLine: String {
        _ = optionsEpoch
        return ModelOptionsFormatting.usingGlobalDefaultLine(
            options: ModelGenerationSettings.options(forSelectionKey: selectionKey),
            capabilities: capabilities
        )
    }

    private func loadOptions() {
        isLoading = true
        let stored = ModelGenerationSettings.options(forSelectionKey: selectionKey)
        let caps = capabilities
        if let storedEffort = stored.reasoningEffort,
           caps.supportedReasoningEfforts.contains(storedEffort) {
            effort = storedEffort
        } else {
            effort = caps.defaultReasoningEffort ?? .medium
        }
        contextTokens = ModelCapabilityCatalog.clampContextTokens(
            stored.contextWindowTokens,
            capabilities: caps
        )
        maxOutputTokens = ModelOptionsFormatting.clampMaxOutputTokens(
            stored.maxOutputTokens,
            capabilities: caps
        )
        rememberThinking = ModelOptionsFormatting.resolvedRememberThinking(
            options: stored,
            capabilities: caps
        )
        DispatchQueue.main.async { isLoading = false }
    }

    private func saveOptions() {
        guard isEditable, !isLoading, parsed != nil else { return }
        ModelGenerationSettings.setOptions(
            ModelOptionsFormatting.optionsToPersist(
                thinking: effort,
                contextWindowTokens: contextTokens,
                maxOutputTokens: maxOutputTokens,
                rememberThinking: rememberThinking,
                capabilities: capabilities
            ),
            forSelectionKey: selectionKey
        )
    }
}

/// Toolbar control that presents the shared Options view in a popover.
///
/// Chat, Research, Email, and other function toolbars use this so Options
/// behave the same everywhere (`ModelPickerOptionsView` in expanded style).
public struct WorkspaceModelOptionsButton: View {
    public let selectionKey: String
    public var isEditable: Bool = true
    public var accessibilityIdentifier: String = "model-options"

    public init(selectionKey: String, isEditable: Bool = true, accessibilityIdentifier: String = "model-options") {
        self.selectionKey = selectionKey
        self.isEditable = isEditable
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    @State private var isPresented = false

    public var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label("Options", systemImage: "slider.horizontal.3")
        }
        .popover(isPresented: $isPresented) {
            ModelPickerOptionsView(
                selectionKey: selectionKey,
                style: .expanded,
                isEditable: isEditable
            )
            .padding()
            .frame(minWidth: 280)
        }
        .help("Thinking and context for this model")
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
