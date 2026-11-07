// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// Deep-link from a task change-log row to a Document or Research item.
public struct WorkspaceOpenRequest: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case document
        case research
    }

    public static let notification = Notification.Name("anaiodyssey.workspace.openRequest")
    public static let kindKey = "kind"
    public static let itemIDKey = "itemID"

    public let kind: Kind
    public let itemID: String

    private static var pending: WorkspaceOpenRequest?

    public static func post(kind: Kind, itemID: String) {
        let request = WorkspaceOpenRequest(kind: kind, itemID: itemID)
        pending = request
        NotificationCenter.default.post(
            name: notification,
            object: nil,
            userInfo: [kindKey: kind.rawValue, itemIDKey: itemID]
        )
    }

    /// Destination views call this on appear so a request is not lost if they
    /// were not mounted when the notification fired.
    public static func takePending(kind: Kind) -> WorkspaceOpenRequest? {
        guard pending?.kind == kind else { return nil }
        let value = pending
        pending = nil
        return value
    }

    public init(kind: Kind, itemID: String) {
        self.kind = kind
        self.itemID = itemID
    }

    public init?(notification: Notification) {
        guard let raw = notification.userInfo?[Self.kindKey] as? String,
              let kind = Kind(rawValue: raw),
              let itemID = notification.userInfo?[Self.itemIDKey] as? String
        else {
            return nil
        }
        self.kind = kind
        self.itemID = itemID
    }
}
