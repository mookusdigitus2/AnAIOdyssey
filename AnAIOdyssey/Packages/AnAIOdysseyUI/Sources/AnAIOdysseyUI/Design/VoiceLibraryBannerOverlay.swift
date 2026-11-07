// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import AnAIOdysseyAI
import AIModelOptions
import SwiftUI

private struct VoiceLibraryBannerOverlay: ViewModifier {
    @ObservedObject var center: VoiceLibraryBannerCenter

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let banner = center.banner {
                HStack(spacing: 12) {
                    Image(systemName: banner.isProblem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(banner.isProblem ? .orange : .green)
                    Text(banner.message)
                        .font(.callout)
                        .accessibilityIdentifier("voice-library-banner-message")
                    Spacer(minLength: 8)
                    if banner.showsRetry {
                        Button("Retry") { center.retry() }
                            .accessibilityIdentifier("voice-library-banner-retry")
                    }
                    Button {
                        center.dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Dismiss")
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityIdentifier("voice-library-banner")
            }
        }
        .animation(.easeInOut(duration: 0.2), value: center.banner)
    }
}

public extension View {
    /// App-wide banner for finished ElevenLabs voice adds and voice-control failures.
    func voiceLibraryBanner() -> some View {
        modifier(VoiceLibraryBannerOverlay(center: .shared))
    }
}
