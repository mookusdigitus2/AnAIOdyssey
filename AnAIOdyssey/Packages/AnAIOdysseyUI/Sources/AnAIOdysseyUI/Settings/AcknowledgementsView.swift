// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import AnAIOdysseyCore
import SwiftUI

/// Settings > About > Acknowledgements: a plain scrolling list of every bundled
/// package with its full license (and NOTICE) text, followed by the app's own
/// AGPL notice and app store permission. Read from the bundled
/// `ThirdPartyNotices` folder so it always matches the repo's notices file.
public struct AcknowledgementsView: View {
    private struct Section: Identifiable {
        let notice: ThirdPartyNotice
        let texts: [String]
        var id: String { notice.id }
    }

    private let sections: [Section]
    private let appSection: Section?
    private let loadError: String?

    public init(directory: URL? = ThirdPartyNotices.bundledDirectory()) {
        guard let directory else {
            sections = []; appSection = nil
            loadError = "License notices are missing from this build."
            return
        }
        do {
            let manifest = try ThirdPartyNotices.load(directory: directory)
            func section(_ notice: ThirdPartyNotice) -> Section {
                Section(notice: notice, texts: notice.files.map {
                    (try? ThirdPartyNotices.text(of: $0, in: directory)) ?? ""
                })
            }
            sections = manifest.packages.map(section)
            appSection = section(manifest.app)
            loadError = nil
        } catch {
            sections = []; appSection = nil
            loadError = "Couldn't read the license notices: \(error.localizedDescription)"
        }
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if let loadError {
                    Text(loadError).foregroundStyle(.secondary)
                }
                ForEach(sections) { entry($0) }
                if let appSection {
                    Divider()
                    entry(appSection)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("acknowledgements-list")
        .navigationTitle("Acknowledgements")
    }

    private func entry(_ section: Section) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.notice.name)
                .font(.headline)
            Text([section.notice.version, section.notice.license].compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let note = section.notice.note, !note.isEmpty {
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(Array(section.texts.enumerated()), id: \.offset) { _, text in
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("acknowledgement-\(section.notice.id)")
    }
}
