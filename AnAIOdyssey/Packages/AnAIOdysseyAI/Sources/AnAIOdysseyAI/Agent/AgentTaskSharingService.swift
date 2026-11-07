// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// Bonjour/mDNS discovery stub for sharing agent tasks across clients on a LAN.
///
/// Full task replication is not implemented yet; this publishes and browses the
/// `_anaiodyssey-agent._tcp` service type so multiple AnAIOdyssey instances can find
/// each other. See SPEC §16.3.
@MainActor
public final class AgentTaskSharingService: NSObject, ObservableObject {
    public static let serviceType = "_anaiodyssey-agent._tcp."
    public static let serviceDomain = "local."

    @Published public private(set) var discoveredPeers: [String] = []
    @Published public private(set) var isPublishing = false

    #if canImport(Network)
    // NetService is in Foundation on Apple platforms.
    private var netService: NetService?
    private var browser: NetServiceBrowser?
    #endif

    public override init() {
        super.init()
    }

    public func startPublishing(port: Int = 8765) {
        #if os(iOS) || os(macOS)
        stopPublishing()
        let service = NetService(
            domain: Self.serviceDomain,
            type: Self.serviceType,
            name: ProcessInfo.processInfo.hostName,
            port: Int32(port)
        )
        service.publish()
        netService = service
        isPublishing = true
        #endif
    }

    public func stopPublishing() {
        netService?.stop()
        netService = nil
        isPublishing = false
    }

    public func startBrowsing() {
        #if os(iOS) || os(macOS)
        stopBrowsing()
        let b = NetServiceBrowser()
        b.delegate = self
        b.searchForServices(ofType: Self.serviceType, inDomain: Self.serviceDomain)
        browser = b
        #endif
    }

    public func stopBrowsing() {
        browser?.stop()
        browser = nil
        discoveredPeers = []
    }
}

#if os(iOS) || os(macOS)
extension AgentTaskSharingService: NetServiceBrowserDelegate {
    nonisolated public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        Task { @MainActor in
            if !discoveredPeers.contains(service.name) {
                discoveredPeers.append(service.name)
            }
        }
    }

    nonisolated public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        Task { @MainActor in
            discoveredPeers.removeAll { $0 == service.name }
        }
    }
}
#endif
