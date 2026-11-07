// SPDX-License-Identifier: MIT
import SwiftUI

/// An inline status line (error, success or info) for the connection screens.
struct ConnectionStatusMessage: View {
    enum Kind {
        case error
        case success
        case info

        var symbol: String {
            switch self {
            case .error: "exclamationmark.triangle.fill"
            case .success: "checkmark.circle.fill"
            case .info: "info.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .error: .red
            case .success: .green
            case .info: .secondary
            }
        }
    }

    let kind: Kind
    let text: String
    /// Long results (like a connection test) scroll and can be selected.
    var scrollable: Bool = false

    var body: some View {
        Group {
            if scrollable {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: kind.symbol)
                        .foregroundStyle(kind.tint)
                    ScrollView {
                        Text(text)
                            .font(.caption)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                }
            } else {
                Label {
                    Text(text)
                } icon: {
                    Image(systemName: kind.symbol)
                }
                .foregroundStyle(kind.tint)
                .font(.caption)
            }
        }
        .accessibilityLabel(text)
    }
}

extension View {
    /// Independent tap target inside a Form or List row.
    public func connectionFormButton() -> some View {
        buttonStyle(.borderless)
    }

    /// URL and key fields: no autocapitalization or autocorrection.
    public func connectionSettingsField() -> some View {
        self
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .autocorrectionDisabled()
            #if os(macOS)
            .textFieldStyle(.plain)
            #endif
    }
}
