// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import AnAIOdysseyAI
import AIModelOptions
import SwiftUI

/// Chat composer mic button driven by `VoiceSessionController` state.
/// Tap → "Starting" with a spinner and a light haptic at once; while
/// listening a level ring follows the mic. There is no "stopping" look: Stop
/// returns to idle immediately and the button stays enabled during cleanup.
struct VoiceMicButton: View {
    @ObservedObject var session: VoiceSessionController
    let isSpokenReplyInterruptible: Bool
    let showsInterruptHint: Bool
    let isEnabled: Bool
    let action: () -> Void
    @State private var tapCount = 0

    var body: some View {
        Button {
            tapCount += 1
            action()
        } label: {
            label
        }
        .labelStyle(.iconOnly)
        .foregroundStyle(isSpokenReplyInterruptible || session.state.isActive ? Color.red : Color.primary)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(isSpokenReplyInterruptible ? "Tap to interrupt" : "")
        .accessibilityIdentifier("chat-voice-button")
        .disabled(!isEnabled)
        .sensoryFeedback(.impact(weight: .light), trigger: tapCount)
    }

    @ViewBuilder
    private var label: some View {
        if isSpokenReplyInterruptible {
            VStack(spacing: 2) {
                Image(systemName: "stop.fill")
                if showsInterruptHint {
                    Text("Tap to interrupt")
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(minWidth: 56)
        } else {
            switch session.state {
            case .starting:
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Starting")
                        .font(.caption)
                }
                .accessibilityIdentifier("chat-voice-starting")
            case .listening:
                Label("Exit voice control", systemImage: "mic.fill")
                    .background { VoiceLevelRing(session: session) }
            case .thinking, .speaking, .pausedAwaitingContinue:
                Label("Exit voice control", systemImage: "mic.fill")
            case .idle, .error:
                Label("Voice control", systemImage: "mic")
            }
        }
    }

    private var accessibilityLabel: String {
        if isSpokenReplyInterruptible { return "Stop speaking" }
        return session.state.isActive ? "Exit voice control" : "Voice control"
    }

    private var accessibilityValue: String {
        switch session.state {
        case .starting: return "Starting"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        case .pausedAwaitingContinue: return "Paused"
        case .idle, .error: return ""
        }
    }
}

/// Live ring around the mic while listening, from the mic tap's RMS.
private struct VoiceLevelRing: View {
    let session: VoiceSessionController

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { _ in
            // Speech RMS is roughly 0.01–0.1; map to 0…1.
            let level = min(1.0, max(0.0, session.micLevel * 12))
            Circle()
                .stroke(Color.red.opacity(0.3 + 0.6 * level), lineWidth: 2)
                .frame(width: 30, height: 30)
                .scaleEffect(1.0 + 0.45 * level)
                .animation(.easeOut(duration: 0.08), value: level)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
