// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import SwiftUI
import AIModelOptions

/// Shown when speech barged in on a spoken reply: playback is paused (audio
/// keeps buffering) and nothing is spoken. Yes resumes, No drops the reply.
/// The same answers work by voice ("yes", "go on" / "no", "stop").
struct VoiceContinuePromptView: View {
    let onYes: () -> Void
    let onNo: () -> Void

    /// UI tests launch with this argument to render the prompt without a mic.
    static var forcedForUITest: Bool {
        ProcessInfo.processInfo.arguments.contains("UITEST_VOICE_CONTINUE_PROMPT")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(VoiceContinuePromptPolicy.promptText, systemImage: "pause.circle.fill")
                .font(.subheadline.weight(.semibold))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(VoiceContinuePromptPolicy.promptText))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("chat-voice-continue-prompt")
            HStack(spacing: 12) {
                Button(VoiceContinuePromptPolicy.yesTitle, action: onYes)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("chat-voice-continue-yes")
                Button(VoiceContinuePromptPolicy.noTitle, action: onNo)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("chat-voice-continue-no")
            }
            Text("Or just say yes or no.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }
}
