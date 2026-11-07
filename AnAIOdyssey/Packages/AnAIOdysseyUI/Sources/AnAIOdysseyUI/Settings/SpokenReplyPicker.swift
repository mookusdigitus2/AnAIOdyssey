// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import AnAIOdysseyAI
import SwiftUI

/// Settings Form rows for spoken replies. `@ViewBuilder` so Form flattens them;
/// wrapping in a `View` would put Provider, Voice, and Preview in one tappable row.
@ViewBuilder
func SpokenReplyPickerRows(
    agentRegistrySettings: AgentRegistrySettings,
    providerSettings: ProviderSettings
) -> some View {
    WorkspaceVoicePicker(
        agentRegistrySettings: agentRegistrySettings,
        providerSettings: providerSettings,
        showsCredentialFields: true
    ).formRows
    Text("Speech input always uses Apple Speech on this device. Spoken replies use System, or ElevenLabs / OpenAI / xAI when that provider has a working key.")
        .font(.caption)
        .foregroundStyle(.secondary)
}
