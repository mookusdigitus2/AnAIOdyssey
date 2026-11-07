// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// JSON metadata on a `ChatMessage` that points at a gallery (photos) image.
public enum ChatMessageGalleryMetadata {
    private static let imageIDKey = "galleryImageID"

    /// Encodes a gallery image id for storage on `ChatMessage.metadata`.
    public static func encode(galleryImageID: String) -> String {
        let payload = [imageIDKey: galleryImageID]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text
    }

    /// Reads a gallery image id from message metadata, if present.
    public static func galleryImageID(from metadata: String?) -> String? {
        guard let metadata,
              let data = metadata.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object[imageIDKey] as? String,
              !id.isEmpty else {
            return nil
        }
        return id
    }
}
