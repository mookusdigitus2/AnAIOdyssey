// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AnAIOdysseyCore

/// Kind of workspace connection the manager can own.
public enum WorkspaceConnectionKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case google
    case appleMail
    case eventKit
    case preview

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .google: "Google"
        case .appleMail: "Apple Mail"
        case .eventKit: "On This Device"
        case .preview: "Preview"
        }
    }

    public var systemImage: String {
        switch self {
        case .google: "envelope.fill"
        case .appleMail: "mail.stack"
        case .eventKit: "calendar"
        case .preview: "tray.full"
        }
    }
}

/// Capabilities a connection can offer (email, calendar, or both).
public struct WorkspaceConnectionCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let email = WorkspaceConnectionCapabilities(rawValue: 1 << 0)
    public static let calendar = WorkspaceConnectionCapabilities(rawValue: 1 << 1)
    public static let emailAndCalendar: WorkspaceConnectionCapabilities = [.email, .calendar]
}

/// One entry in `WorkspaceConnectionManager`'s connection set.
public struct WorkspaceConnection: Identifiable, Hashable, Sendable {
    public let id: String
    public let kind: WorkspaceConnectionKind
    public let displayName: String
    public let detail: String?
    public let capabilities: WorkspaceConnectionCapabilities
    public let isConnected: Bool

    public init(
        id: String,
        kind: WorkspaceConnectionKind,
        displayName: String,
        detail: String? = nil,
        capabilities: WorkspaceConnectionCapabilities,
        isConnected: Bool
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.detail = detail
        self.capabilities = capabilities
        self.isConnected = isConnected
    }
}

/// Adapter that exposes one connection as a mail backend.
@MainActor
public protocol EmailProviderAdapter {
    var connectionID: String { get }
    var displayName: String { get }
    var isAvailable: Bool { get }
    func makeMailReader() -> any MailReaderServiceProtocol
}
