// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import AnAIOdysseyAI
import AIModelOptions
import SwiftUI

/// Run-center ids shared by Research views and the app shell.
enum ResearchRunIDs {
    static let newQuery = "research.new"
}

extension RunExecution {
    /// On-device MLX / Apple Foundation (and Automatic, which tries MLX first)
    /// can't use the GPU in the background, so those runs stop when the app
    /// leaves the foreground. Remote models keep going.
    @MainActor init(selectionKey: String) {
        let backend = ConfiguredModelRegistry.parseSelectionKey(selectionKey)?.backend
        self = backend == .remote ? .cloud : .onDevice
    }
}

/// Stopped / failed state line with Stop or Resume. Never presents a
/// cut-off run as complete.
struct RunStateControls: View {
    let run: RunSnapshot
    @ObservedObject var center: BackgroundRunCenter

    var body: some View {
        HStack(spacing: 12) {
            if run.isRunning {
                ProgressView().controlSize(.small)
                Button("Stop", role: .destructive) { center.stop(id: run.id) }
                    .accessibilityIdentifier("run-stop-button")
            } else if let message = run.statusMessage {
                Label(message, systemImage: run.phase == .stopped(.leftApp) ? "pause.circle" : "exclamationmark.triangle")
                    .font(AnAIOdysseyFont.metadata)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("run-stopped-message")
                if run.canResume {
                    Button("Resume") { center.resume(id: run.id) }
                        .accessibilityIdentifier("run-resume-button")
                }
            }
        }
    }
}

private struct RunRowAccessory: ViewModifier {
    let run: RunSnapshot?
    @ObservedObject var center: BackgroundRunCenter

    func body(content: Content) -> some View {
        HStack(spacing: 8) {
            content
            if let run {
                Spacer(minLength: 4)
                if run.isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityIdentifier("run-row-spinner")
                    Button {
                        center.stop(id: run.id)
                    } label: {
                        Image(systemName: "stop.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Stop")
                    .accessibilityIdentifier("run-row-stop-button")
                } else if run.canResume {
                    Image(systemName: run.phase == .stopped(.leftApp) ? "pause.circle" : "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(run.statusMessage ?? "Stopped")
                }
            }
        }
    }
}

extension View {
    /// Spinner + Stop on a list row while its run is going; a stopped icon after.
    func runRowAccessory(_ run: RunSnapshot?, center: BackgroundRunCenter) -> some View {
        modifier(RunRowAccessory(run: run, center: center))
    }
}

/// App-wide "finished" banner for Chat / Research runs that ended while the
/// user was elsewhere.
@MainActor
public final class RunCompletionBannerCenter: ObservableObject {
    public static let shared = RunCompletionBannerCenter()
    public struct Banner: Equatable { public let message: String; public let isProblem: Bool }
    @Published public var banner: Banner?
    private var clearTask: Task<Void, Never>?

    public func show(_ snapshot: RunSnapshot, feature: String) {
        let message: String
        switch snapshot.phase {
        case .finished: message = "\(feature) finished: \(snapshot.title)"
        case .stopped(.leftApp): message = "\(feature) stopped when you left the app: \(snapshot.title)"
        case .failed(let error): message = "\(feature) failed: \(error)"
        case .stopped(.user), .running: return
        }
        banner = Banner(message: message, isProblem: snapshot.phase != .finished)
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled { self?.banner = nil }
        }
    }
}

private struct RunCompletionBannerOverlay: ViewModifier {
    @ObservedObject var center: RunCompletionBannerCenter

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let banner = center.banner {
                HStack(spacing: 12) {
                    Image(systemName: banner.isProblem ? "pause.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(banner.isProblem ? .orange : .green)
                    Text(banner.message)
                        .font(.callout)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Button { center.banner = nil } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Dismiss")
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityIdentifier("run-completion-banner")
            }
        }
        .animation(.easeInOut(duration: 0.2), value: center.banner)
    }
}

public extension View {
    /// App-wide banner for Chat / Research runs that finished or stopped.
    func runCompletionBanner() -> some View {
        modifier(RunCompletionBannerOverlay(center: .shared))
    }
}

#if os(iOS)
import UIKit

/// `UIApplication.beginBackgroundTask` — the iOS 17-25 ~30 s grace period.
@MainActor
final class UIApplicationBackgroundAssertion: BackgroundTaskAsserting {
    func begin(name: String, expiration: @escaping () -> Void) -> Int {
        let id = UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated { expiration() }
        }
        return id.rawValue
    }

    func end(_ token: Int) {
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: token))
    }
}
#endif

import UserNotifications

/// Wires the Chat / Research run centers to the app: background time, scene
/// phase, the finish banner and a local notification while backgrounded.
public enum BackgroundRuns {
    @MainActor
    public static func configure() {
        let pairs: [(BackgroundRunCenter, String)] = [
            (ChatGenerationCenter.shared, "Chat"),
            (ResearchRunCenter.shared, "Research"),
        ]
        for (center, feature) in pairs {
            #if os(iOS)
            if center.backgroundAssertion == nil {
                center.backgroundAssertion = UIApplicationBackgroundAssertion()
            }
            #endif
            center.onRunEnded = { [weak center] snapshot in
                guard let center else { return }
                if case .stopped(.user) = snapshot.phase { return }
                if center.isInBackground {
                    postNotification(snapshot, feature: feature)
                } else if !center.watchedIDs.contains(snapshot.id) {
                    RunCompletionBannerCenter.shared.show(snapshot, feature: feature)
                }
            }
        }
    }

    /// Call from the scene's `scenePhase` changes.
    @MainActor
    public static func scenePhaseChanged(_ phase: ScenePhase) {
        let centers = [ChatGenerationCenter.shared, ResearchRunCenter.shared]
        switch phase {
        case .background:
            if centers.contains(where: { $0.activeRunCount > 0 }) {
                // Provisional: delivered quietly, never prompts.
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .provisional]) { _, _ in }
            }
            centers.forEach { $0.sceneDidEnterBackground() }
        case .active:
            centers.forEach { $0.sceneWillEnterForeground() }
        default:
            break
        }
    }

    private static func postNotification(_ snapshot: RunSnapshot, feature: String) {
        let content = UNMutableNotificationContent()
        switch snapshot.phase {
        case .finished:
            content.title = "\(feature) finished"
        case .stopped(.leftApp):
            content.title = "\(feature) stopped when you left the app"
        case .failed:
            content.title = "\(feature) failed"
        default:
            return
        }
        content.body = snapshot.title
        let request = UNNotificationRequest(identifier: "run.\(snapshot.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
