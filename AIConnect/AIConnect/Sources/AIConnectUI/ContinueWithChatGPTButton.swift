// SPDX-License-Identifier: MIT
import AIConnect
import AIModelOptions
import SwiftUI

/// “Continue with ChatGPT” control: exact label, high-contrast fill, no logo.
///
/// OpenAI’s brand rules require the official ChatGPT mark from the brand kit.
/// This repo has no licensed asset, so the button is text-only until one is added.
public struct ContinueWithChatGPTButton: View {
    public var isBusy: Bool = false
    public var action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
                Text("Continue with ChatGPT")
                    .font(.body.weight(.semibold))
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 32)
            .padding(.horizontal, 12)
            .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel("Continue with ChatGPT")
        .accessibilityIdentifier("continue-with-chatgpt")
    }

    private var background: Color {
        colorScheme == .dark ? Color.white : Color.black
    }

    private var foreground: Color {
        colorScheme == .dark ? Color.black : Color.white
    }
}

public struct ChatGPTPlanCaption: View {
    public var body: some View {
        Text(ChatGPTOAuthCodec.planCaption)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// Settings / onboarding offer from OpenAI's UI guidelines: title, caption,
/// and the Continue with ChatGPT action. Kept apart from the app's own API-key
/// billing so the two are never confused.
public struct ChatGPTPlanOffer: View {
    public var isBusy: Bool
    public var action: () -> Void

    public init(isBusy: Bool, action: @escaping () -> Void) {
        self.isBusy = isBusy
        self.action = action
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ChatGPTOAuthCodec.planOfferTitle)
                .font(.headline)
            ChatGPTPlanCaption()
            ContinueWithChatGPTButton(isBusy: isBusy, action: action)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatgpt-plan-offer")
    }
}

/// “Using ChatGPT plan · Manage usage”, shown near the composer and on the
/// connection row whenever requests use the ChatGPT plan.
public struct ChatGPTPlanInUseLabel: View {
    public init() {}

    public var body: some View {
        HStack(spacing: 6) {
            Text(ChatGPTOAuthCodec.planInUseLabel)
                .foregroundStyle(.secondary)
            Link("Manage usage", destination: ChatGPTOAuthCodec.manageUsageURL)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chatgpt-plan-in-use")
    }
}

/// One-time “You’re using your ChatGPT plan” confirmation after the first
/// sign-in with plan usage enabled.
struct ChatGPTPlanNoticeModifier: ViewModifier {
    @ObservedObject var accounts: ChatGPTAccountService
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content.alert(
            ChatGPTOAuthCodec.planNoticeTitle,
            isPresented: Binding(
                get: { accounts.showsPlanNotice },
                set: { if !$0 { accounts.acknowledgePlanNotice() } }
            )
        ) {
            Button("Got it") { accounts.acknowledgePlanNotice() }
                .keyboardShortcut(.defaultAction)
            Button("Manage usage") {
                accounts.acknowledgePlanNotice()
                openURL(ChatGPTOAuthCodec.manageUsageURL)
            }
        } message: {
            Text(ChatGPTOAuthCodec.planNoticeMessage)
        }
    }
}

extension View {
    public func chatGPTPlanNotice(_ accounts: ChatGPTAccountService) -> some View {
        modifier(ChatGPTPlanNoticeModifier(accounts: accounts))
    }
}
