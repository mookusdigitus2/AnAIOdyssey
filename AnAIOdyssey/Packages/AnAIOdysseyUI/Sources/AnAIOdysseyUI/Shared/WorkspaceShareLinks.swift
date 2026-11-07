// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import AnAIOdysseyAI
import AnAIOdysseyCore
import SwiftUI
import UniformTypeIdentifiers

#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Transferable wrapper so the share sheet receives the real image file.
///
/// `FileRepresentation` keeps AirDrop / Save Image on the file (and its UTI).
/// `ProxyRepresentation` also exposes the file URL for destinations that want a URL.
struct ShareableImageFile: Transferable {
    let url: URL
    let title: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .image) { item in
            SentTransferredFile(item.url)
        }
        ProxyRepresentation(exporting: \.url)
    }
}

/// Standard ShareLink for a plain-text chat, document, research result, or message.
struct WorkspaceTextShareLink: View {
    let title: String
    let text: String
    var accessibilityIdentifier: String = "share-button"

    var body: some View {
        ShareLink(
            item: text,
            subject: Text(title),
            preview: SharePreview(title)
        ) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .help("Share")
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/// Standard ShareLink for a gallery image file.
struct WorkspaceImageShareLink: View {
    let title: String
    let fileURL: URL
    var accessibilityIdentifier: String = "share-image-button"

    var body: some View {
        if let previewImage {
            imageShareLink(preview: SharePreview(title, image: previewImage))
        } else {
            imageShareLink(preview: SharePreview(title))
        }
    }

    private func imageShareLink<PreviewImage: Transferable, PreviewIcon: Transferable>(
        preview: SharePreview<PreviewImage, PreviewIcon>
    ) -> some View {
        ShareLink(
            item: ShareableImageFile(url: fileURL, title: title),
            preview: preview
        ) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .help("Share")
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var previewImage: Image? {
        #if os(macOS)
        guard let nsImage = NSImage(contentsOf: fileURL) else { return nil }
        return Image(nsImage: nsImage)
        #elseif os(iOS)
        guard let uiImage = UIImage(contentsOfFile: fileURL.path) else { return nil }
        return Image(uiImage: uiImage)
        #else
        return nil
        #endif
    }
}

/// Shares the audio debug log as a .txt file (a String item from a Form row
/// did nothing on device). Exported fresh each time the row appears.
struct AudioDebugLogShareLink: View {
    @State private var fileURL: URL?

    var body: some View {
        Group {
            if let fileURL {
                ShareLink(
                    item: fileURL,
                    subject: Text("Audio debug log"),
                    preview: SharePreview("Audio debug log")
                ) {
                    Label("Share audio debug log", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
            } else {
                Label("Share audio debug log", systemImage: "square.and.arrow.up")
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("share-audio-debug-log-button")
        .onAppear { fileURL = VoiceAudioDebugStore.exportForSharing() }
    }
}
