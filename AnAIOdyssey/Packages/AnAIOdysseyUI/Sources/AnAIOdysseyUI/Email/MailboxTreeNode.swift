// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation
import AnAIOdysseyMail

/// A node in the per-account mailbox hierarchy, derived from mailbox display
/// paths. `mailbox` is `nil` for an intermediate grouping folder that has no
/// label of its own; `children` is `nil` for leaves (so no disclosure triangle).
struct MailboxTreeNode: Identifiable {
    let id: String
    let title: String
    let mailbox: MailMailbox?
    var children: [MailboxTreeNode]?

    /// Builds a forest from mailboxes, preserving the input order of first sight.
    static func build(from mailboxes: [MailMailbox], keyPrefix: String) -> [MailboxTreeNode] {
        // Mutable trie used only during construction.
        final class Builder {
            let title: String
            let key: String
            var mailbox: MailMailbox?
            var order: [String] = []
            var children: [String: Builder] = [:]
            init(title: String, key: String) {
                self.title = title
                self.key = key
            }
        }

        let root = Builder(title: "", key: keyPrefix)
        for mailbox in mailboxes {
            let path = mailbox.displayPath ?? [mailbox.displayName]
            var node = root
            for component in path {
                let childKey = node.key + "/" + component
                if let existing = node.children[component] {
                    node = existing
                } else {
                    let child = Builder(title: component, key: childKey)
                    node.children[component] = child
                    node.order.append(component)
                    node = child
                }
            }
            node.mailbox = mailbox
        }

        func convert(_ builder: Builder) -> [MailboxTreeNode] {
            builder.order.map { component in
                let child = builder.children[component]!
                let kids = convert(child)
                return MailboxTreeNode(
                    id: child.key,
                    title: child.title,
                    mailbox: child.mailbox,
                    children: kids.isEmpty ? nil : kids
                )
            }
        }
        return convert(root)
    }
}
