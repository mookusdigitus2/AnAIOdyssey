// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import AnAIOdysseyAI
import SwiftUI

/// Searchable list of every available model; Compare does not filter or default.
struct CompareModelMultiSelect: View {
    @Binding var selectedKeys: Set<String>
    let choices: [ConfiguredModelChoice]

    @State private var query = ""

    private var filtered: [ConfiguredModelChoice] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return choices }
        return choices.filter {
            $0.pickerLabel.localizedCaseInsensitiveContains(trimmed)
                || $0.id.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search models", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("compare-model-search")
            if !selectedKeys.isEmpty {
                Text("\(selectedKeys.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(filtered, id: \.selectionKey) { choice in
                        Toggle(isOn: binding(for: choice.selectionKey)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(choice.displayName)
                                Text(choice.pickerLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("compare-model-\(choice.id)")
                    }
                }
            }
            .frame(minHeight: 160, maxHeight: 280)
        }
    }

    private func binding(for key: String) -> Binding<Bool> {
        Binding(
            get: { selectedKeys.contains(key) },
            set: { isOn in
                if isOn {
                    selectedKeys.insert(key)
                } else {
                    selectedKeys.remove(key)
                }
            }
        )
    }
}
