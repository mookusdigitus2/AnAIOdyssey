// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import SwiftUI

private struct AgentControllerKey: EnvironmentKey {
    static let defaultValue: AgentController? = nil
}

private struct VoiceServiceKey: @preconcurrency EnvironmentKey {
    /// Voice input is backed by Apple Speech regardless of the selected output
    /// provider, so views outside the app composition root retain a functional
    /// microphone rather than rendering its control as unavailable.
    @MainActor static let defaultValue: any VoiceServiceProtocol = SystemVoiceService()
}

public extension EnvironmentValues {
    var agentController: AgentController? {
        get { self[AgentControllerKey.self] }
        set { self[AgentControllerKey.self] = newValue }
    }

    var voiceService: any VoiceServiceProtocol {
        get { self[VoiceServiceKey.self] }
        set { self[VoiceServiceKey.self] = newValue }
    }
}
