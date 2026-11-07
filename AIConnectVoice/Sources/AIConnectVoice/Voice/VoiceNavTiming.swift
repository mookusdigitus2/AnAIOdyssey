// SPDX-License-Identifier: MIT
import Foundation
import AIConnect
import os
#if canImport(UIKit)
import UIKit
#endif

/// Back-navigation timing: a signpost interval from the Back tap to the chat
/// list's first appearance and first drawn frame, plus OSLog lines and
/// VoiceAudioDebugStore events with the elapsed milliseconds.
///
/// Read them with:
/// `xcrun simctl spawn booted log show --last 5m --predicate 'subsystem == "com.example.anaiodyssey" AND category == "VoiceNav"'`
@MainActor
public enum VoiceNavTiming {
    public static let subsystem = "com.example.anaiodyssey"
    private static let logger = Logger(subsystem: subsystem, category: "VoiceNav")
    private static let signposter = OSSignposter(subsystem: subsystem, category: "VoiceNav")

    private struct Pending {
        var id: Int
        var context: String
        var tappedAt: UInt64
        var interval: OSSignpostIntervalState
        var appeared = false
    }

    private static var pending: Pending?
    private static var nextID = 0
    #if canImport(UIKit)
    private static var displayLink: CADisplayLink?
    private static let frameTarget = FrameTarget()
    #endif

    /// Back tapped. `context` is the voice state at the tap (idle / listening / speaking...).
    public static func backTapped(context rawContext: String) {
        // The controller can still say "listening" while a reply is playing;
        // record what the engine is actually doing.
        let engine = VoiceDuplexEngine.shared
        let context = "\(rawContext) playback=\(engine.isPlayingBack) engine=\(engine.isEngineRunning)"
        if let stale = pending {
            signposter.endInterval("BackToList", stale.interval, "superseded")
        }
        nextID += 1
        let interval = signposter.beginInterval("BackToList", id: signposter.makeSignpostID(), "ctx=\(context, privacy: .public)")
        pending = Pending(id: nextID, context: context, tappedAt: DispatchTime.now().uptimeNanoseconds, interval: interval)
        logger.notice("back.tap id=\(nextID, privacy: .public) ctx=\(context, privacy: .public)")
        VoiceAudioDebugStore.append(event: "nav.back.tap", detail: "id=\(nextID) ctx=\(context)")
    }

    /// The chat list's `onAppear`. Arms a one-shot display link so the next
    /// frame the list is part of is logged as its first draw.
    public static func listAppeared() {
        guard var current = pending, !current.appeared else { return }
        current.appeared = true
        pending = current
        let ms = elapsedMilliseconds(since: current.tappedAt)
        signposter.emitEvent("ListAppear", "id=\(current.id, privacy: .public)")
        logger.notice("list.appear id=\(current.id, privacy: .public) ctx=\(current.context, privacy: .public) ms=\(ms, format: .fixed(precision: 1), privacy: .public)")
        VoiceAudioDebugStore.append(event: "nav.list.appear", detail: "id=\(current.id) ctx=\(current.context) ms=\(String(format: "%.1f", ms))")
        #if canImport(UIKit)
        displayLink?.invalidate()
        let link = CADisplayLink(target: frameTarget, selector: #selector(FrameTarget.tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
        #else
        listFirstFrame()
        #endif
    }

    static func listFirstFrame() {
        #if canImport(UIKit)
        displayLink?.invalidate()
        displayLink = nil
        #endif
        guard let current = pending else { return }
        pending = nil
        let ms = elapsedMilliseconds(since: current.tappedAt)
        signposter.endInterval("BackToList", current.interval, "first frame")
        logger.notice("list.firstFrame id=\(current.id, privacy: .public) ctx=\(current.context, privacy: .public) ms=\(ms, format: .fixed(precision: 1), privacy: .public)")
        VoiceAudioDebugStore.append(event: "nav.list.firstFrame", detail: "id=\(current.id) ctx=\(current.context) ms=\(String(format: "%.1f", ms))")
    }

    private static func elapsedMilliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    #if canImport(UIKit)
    private final class FrameTarget: NSObject {
        @objc func tick() {
            MainActor.assumeIsolated { VoiceNavTiming.listFirstFrame() }
        }
    }
    #endif
}
