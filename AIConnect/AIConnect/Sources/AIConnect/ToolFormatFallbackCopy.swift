// SPDX-License-Identifier: MIT
import Foundation

/// User-facing sentence when a model answered in text instead of a tool call.
/// This is UI copy, not a model prompt.
public enum ToolFormatFallbackCopy {
    public static let changeButtonTitle = "Change Tool Format"

    public static func message(model: String) -> String {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = name.isEmpty ? "This model" : name
        return "\(subject) answered without using its tools. Try a different Tool Format in this connection's Advanced settings."
    }
}
