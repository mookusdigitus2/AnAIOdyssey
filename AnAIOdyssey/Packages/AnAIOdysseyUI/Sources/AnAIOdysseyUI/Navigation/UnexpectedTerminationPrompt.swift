// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import AnAIOdysseyAI
import AIModelOptions
import SwiftUI

/// One-time prompt after a crash or watchdog, so the user can share the audio log.
struct UnexpectedTerminationPromptModifier: ViewModifier {
    @State private var showPrompt = false
    @State private var shareLog = false
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear {
                let clean = UserDefaults.standard.bool(forKey: UnexpectedTerminationPolicy.cleanExitKey)
                if UnexpectedTerminationPolicy.shouldPromptForAudioLog(
                    cleanExitFlag: clean,
                    hasAudioLog: VoiceAudioDebugStore.hasLog()
                ) {
                    showPrompt = true
                }
                UserDefaults.standard.set(false, forKey: UnexpectedTerminationPolicy.cleanExitKey)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    UserDefaults.standard.set(true, forKey: UnexpectedTerminationPolicy.cleanExitKey)
                } else if phase == .active {
                    UserDefaults.standard.set(false, forKey: UnexpectedTerminationPolicy.cleanExitKey)
                }
            }
            .confirmationDialog(
                UnexpectedTerminationPolicy.promptCopy,
                isPresented: $showPrompt,
                titleVisibility: .visible
            ) {
                Button("Share") { shareLog = true }
                Button("Not Now", role: .cancel) {}
            }
            .sheet(isPresented: $shareLog) {
                NavigationStack {
                    Form {
                        AudioDebugLogShareLink()
                    }
                    .navigationTitle("Share audio debug log")
                }
            }
    }
}

extension View {
    func unexpectedTerminationAudioLogPrompt() -> some View {
        modifier(UnexpectedTerminationPromptModifier())
    }
}
