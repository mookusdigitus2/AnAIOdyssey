// SPDX-License-Identifier: MIT
import SwiftUI
import AIConnect
import AIModelOptions

/// What an app that drives a tool-calling agent adds to the shared connection screens: which
/// connection types it can use, the stored tool-test results, and how to run the test call.
public struct ConnectionModelDetails {
    public let store: ToolCallVerificationStore
    public let usableEncodings: Set<RemoteProtocolEncoding>
    public let testToolCall: @MainActor (RemoteConnection, String) async -> (passed: Bool, detail: String)
    /// The test call with an inconclusive result: `passed` is nil for a timeout or server
    /// error, which is shown but not saved as a failed test.
    public let testToolCallOutcome: @MainActor (RemoteConnection, String) async -> (passed: Bool?, detail: String)

    public init(
        store: ToolCallVerificationStore,
        usableEncodings: Set<RemoteProtocolEncoding>,
        testToolCall: @escaping @MainActor (RemoteConnection, String) async -> (passed: Bool, detail: String)
    ) {
        self.store = store
        self.usableEncodings = usableEncodings
        self.testToolCall = testToolCall
        self.testToolCallOutcome = { connection, modelID in
            let result = await testToolCall(connection, modelID)
            return (result.passed, result.detail)
        }
    }

    public init(
        store: ToolCallVerificationStore,
        usableEncodings: Set<RemoteProtocolEncoding>,
        testToolCallOutcome: @escaping @MainActor (RemoteConnection, String) async -> (passed: Bool?, detail: String)
    ) {
        self.store = store
        self.usableEncodings = usableEncodings
        self.testToolCallOutcome = testToolCallOutcome
        self.testToolCall = { connection, modelID in
            let result = await testToolCallOutcome(connection, modelID)
            return (result.passed ?? false, result.detail)
        }
    }

    public func availability(of choice: ConfiguredModelChoice, connection: RemoteConnection?) -> ToolModelAvailability {
        ToolModelPolicy.availability(of: choice, connection: connection, store: store, usableEncodings: usableEncodings)
    }

    func availability(modelID: String, connection: RemoteConnection) -> ToolModelAvailability {
        availability(of: ConfiguredModelChoice(id: modelID, displayName: modelID, backend: .remote,
                                               providerLabel: connection.trimmedName, connectionID: connection.id),
                     connection: connection)
    }
}

extension ToolModelAvailability {
    var statusText: String {
        switch self {
        case .ready: "Calls tools"
        case .needsTest: ToolModelPolicy.untestedLabel
        case .failedTest: ToolModelPolicy.failedTestReason
        case .unavailable(let reason): reason
        }
    }

    var statusColor: Color {
        switch self {
        case .ready: .green
        case .needsTest: .secondary
        case .failedTest: .orange
        case .unavailable: .red
        }
    }
}

/// Model picker for an agent that calls tools: grouped by connection, models without tool
/// support dimmed with the reason, and an untested (or failed) model tested before it's picked.
public struct ToolModelMenu: View {
    @Binding var selectionKey: String
    @ObservedObject var providerSettings: ProviderSettings
    let details: ConnectionModelDetails
    var accessibilityIdentifier: String
    var showsFailureInline: Bool
    var onTestFailed: ((String) -> Void)?

    @State private var testingKey: String?
    @State private var failure: String?
    @State private var verdictEpoch = 0

    public init(
        selectionKey: Binding<String>,
        providerSettings: ProviderSettings,
        details: ConnectionModelDetails,
        accessibilityIdentifier: String,
        showsFailureInline: Bool = true,
        onTestFailed: ((String) -> Void)? = nil
    ) {
        _selectionKey = selectionKey
        self.providerSettings = providerSettings
        self.details = details
        self.accessibilityIdentifier = accessibilityIdentifier
        self.showsFailureInline = showsFailureInline
        self.onTestFailed = onTestFailed
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Menu {
                ForEach(groups) { group in
                    Section(group.title) {
                        ForEach(group.choices, id: \.selectionKey) { choice in
                            item(choice)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    if testingKey != nil { ProgressView().controlSize(.mini) }
                    Text(testingKey != nil ? "Testing tool calls…" : currentLabel)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                }
            }
            .disabled(testingKey != nil)
            .accessibilityIdentifier(accessibilityIdentifier)
            .accessibilityValue(currentLabel)
            if showsFailureInline, let failure {
                Text(failure).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var choices: [ConfiguredModelChoice] {
        _ = verdictEpoch
        return ConfiguredModelRegistry.pickerChoices(
            providerSettings: providerSettings,
            selectionKey: selectionKey,
            offerLocalMLX: false
        )
    }

    private var groups: [ModelChoiceGroup] { ToolModelPolicy.grouped(choices) }

    private var currentLabel: String {
        ConfiguredModelRegistry.choice(forSelectionKey: selectionKey, providerSettings: providerSettings)?.pickerLabel
            ?? "Pick a model"
    }

    @ViewBuilder
    private func item(_ choice: ConfiguredModelChoice) -> some View {
        let state = details.availability(of: choice, connection: choice.connectionID.flatMap(providerSettings.connection(id:)))
        Button {
            pick(choice, state)
        } label: {
            if choice.selectionKey == selectionKey {
                Label(choice.displayName, systemImage: "checkmark")
            } else {
                Text(choice.displayName)
            }
            switch state {
            case .ready: EmptyView()
            case .needsTest: Text("\(ToolModelPolicy.untestedLabel) · tests tool calls when picked")
            case .failedTest: Text("\(ToolModelPolicy.failedTestReason) · pick to test again")
            case .unavailable(let reason) where Self.offersTest(choice, state): Text("\(reason) · pick to test tool calls")
            case .unavailable(let reason): Text(reason)
            }
        }
        .disabled(!Self.offersTest(choice, state))
    }

    /// A test needs a connection and a chat model: on-device models and embedding rows can't be tested.
    static func offersTest(_ choice: ConfiguredModelChoice, _ state: ToolModelAvailability) -> Bool {
        if state.isSelectable { return true }
        return state.canRunToolTest && choice.connectionID != nil && ModelCapabilityCatalog.isChatModel(choice.id)
    }

    private func pick(_ choice: ConfiguredModelChoice, _ state: ToolModelAvailability) {
        failure = nil
        switch state {
        case .ready:
            selectionKey = choice.selectionKey
        case .unavailable where !state.runsTestWhenPicked || !Self.offersTest(choice, state):
            break
        case .needsTest, .failedTest, .unavailable:
            guard let id = choice.connectionID, let connection = providerSettings.connection(id: id) else { return }
            let key = choice.selectionKey
            testingKey = key
            Task { @MainActor in
                let result = await details.testToolCallOutcome(connection, choice.id)
                details.store.recordIfConclusive(passed: result.passed, for: key)
                testingKey = nil
                verdictEpoch += 1
                switch result.passed {
                case true?:
                    selectionKey = key
                case false?:
                    let message = "\(choice.displayName) failed the tool test: \(result.detail)"
                    failure = message
                    onTestFailed?(message)
                case nil:
                    let message = "\(choice.displayName) couldn't finish the tool test: \(result.detail)"
                    failure = message
                    onTestFailed?(message)
                }
            }
        }
    }
}

/// Connection detail rows for one model: tool support, a Test Tools button, and the model's
/// own Options (thinking level offered only when the model takes one, context, max output).
struct ConnectionModelRows: View {
    let connection: RemoteConnection
    let modelID: String
    let details: ConnectionModelDetails
    @State private var testing = false
    @State private var lastDetail: String?
    @State private var epoch = 0

    var body: some View {
        let state = { _ = epoch; return details.availability(modelID: modelID, connection: connection) }()
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(ModelCapabilityCatalog.displayName(forModelID: modelID, backend: .remote))
                if ModelCapabilityCatalog.displayName(forModelID: modelID, backend: .remote) != modelID {
                    Text(modelID).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if modelID == connection.trimmedModel {
                Text("Default").font(.caption).foregroundStyle(.secondary)
            }
            Text(state.statusText)
                .font(.caption)
                .foregroundStyle(state.statusColor)
                .accessibilityIdentifier("tool-status-\(modelID)")
        }
        // Any model the app can drive can be tested (again) here, including one that passed and one
        // marked "Doesn't support tools". The result replaces whatever was saved.
        if state.canRunToolTest, ModelCapabilityCatalog.isChatModel(modelID) {
            Button(testing ? "Testing…" : "Test Tool Calls") {
                testing = true
                Task { @MainActor in
                    let result = await details.testToolCallOutcome(connection, modelID)
                    details.store.recordIfConclusive(passed: result.passed, for: selectionKey)
                    lastDetail = result.passed == true ? nil : result.detail
                    testing = false
                    epoch += 1
                }
            }
            .connectionFormButton()
            .font(.caption)
            .disabled(testing)
            .accessibilityIdentifier("test-tools-\(modelID)")
            if let lastDetail {
                ConnectionStatusMessage(kind: .error, text: lastDetail)
            }
        }
        ModelPickerOptionsView(selectionKey: selectionKey, style: .collapsed)
    }

    private var selectionKey: String {
        ConfiguredModelRegistry.selectionKey(modelID: modelID, backend: .remote, connectionID: connection.id)
    }
}
