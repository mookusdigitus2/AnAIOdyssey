// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import Foundation

/// Minimal ZIP (STORE / method 0) writer and reader used by workspace archives.
///
/// Compression is intentionally skipped: the archive is a portable container for
/// JSON plus gallery/context files, and STORE keeps the implementation small and
/// correct on both macOS and iOS (no `/usr/bin/unzip`). Paths are stored with
/// `/` separators; extraction rejects `..` and absolute paths (zip-slip).
enum ZipStore {
    /// Writes `files` (archive-relative path → bytes) to `url` as a ZIP.
    static func zip(files: [String: Data], to url: URL) throws {
        let sorted = files.keys.sorted().compactMap { path -> (String, Data)? in
            let normalized = normalizePath(path)
            guard !normalized.isEmpty, let data = files[path] else { return nil }
            return (normalized, data)
        }

        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var centralDirectory = Data()
        var entryCount: UInt16 = 0

        for (path, data) in sorted {
            let nameData = Data(path.utf8)
            guard nameData.count <= Int(UInt16.max) else {
                throw ZipStoreError.pathTooLong(path)
            }
            let offset = try handle.offset()
            let crc = CRC32.hash(data)
            let size = UInt32(data.count)

            var local = Data()
            local.appendUInt32(0x04034b50)
            local.appendUInt16(20)
            local.appendUInt16(0x0800)
            local.appendUInt16(0)
            local.appendUInt16(0)
            local.appendUInt16(0)
            local.appendUInt32(crc)
            local.appendUInt32(size)
            local.appendUInt32(size)
            local.appendUInt16(UInt16(nameData.count))
            local.appendUInt16(0)
            local.append(nameData)
            try handle.write(contentsOf: local)
            try handle.write(contentsOf: data)

            var central = Data()
            central.appendUInt32(0x02014b50)
            central.appendUInt16(20)
            central.appendUInt16(20)
            central.appendUInt16(0x0800)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt32(crc)
            central.appendUInt32(size)
            central.appendUInt32(size)
            central.appendUInt16(UInt16(nameData.count))
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt32(0)
            central.appendUInt32(UInt32(offset))
            central.append(nameData)
            centralDirectory.append(central)
            entryCount += 1
        }

        let centralOffset = try handle.offset()
        try handle.write(contentsOf: centralDirectory)

        var eocd = Data()
        eocd.appendUInt32(0x06054b50)
        eocd.appendUInt16(0)
        eocd.appendUInt16(0)
        eocd.appendUInt16(entryCount)
        eocd.appendUInt16(entryCount)
        eocd.appendUInt32(UInt32(centralDirectory.count))
        eocd.appendUInt32(UInt32(centralOffset))
        eocd.appendUInt16(0)
        try handle.write(contentsOf: eocd)
    }

    /// Extracts every file from `archiveURL` into `destinationURL`, creating
    /// intermediate directories as needed.
    static func unzip(_ archiveURL: URL, to destinationURL: URL) throws {
        let data = try Data(contentsOf: archiveURL)
        let entries = try readEntries(from: data)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        for (path, bytes) in entries {
            let dest = destinationURL.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try bytes.write(to: dest, options: .atomic)
        }
    }

    /// Reads the archive into memory keyed by relative path (tests / small zips).
    static func unzip(_ archiveURL: URL) throws -> [String: Data] {
        try readEntries(from: Data(contentsOf: archiveURL))
    }

    /// Parses a ZIP (STORE only) into path → bytes.
    private static func readEntries(from data: Data) throws -> [String: Data] {
        guard let eocdOffset = findEOCDOffset(in: data) else {
            throw ZipStoreError.invalidArchive
        }

        let diskEntries = data.readUInt16(at: eocdOffset + 8)
        let totalEntries = data.readUInt16(at: eocdOffset + 10)
        let centralSize = Int(data.readUInt32(at: eocdOffset + 12))
        let centralOffset = Int(data.readUInt32(at: eocdOffset + 16))
        guard diskEntries == totalEntries, centralOffset >= 0, centralOffset + centralSize <= data.count else {
            throw ZipStoreError.unsupportedArchive
        }

        var files: [String: Data] = [:]
        var cursor = centralOffset
        let centralEnd = centralOffset + centralSize
        while cursor + 46 <= centralEnd {
            guard data.readUInt32(at: cursor) == 0x02014b50 else {
                throw ZipStoreError.invalidArchive
            }
            let flags = data.readUInt16(at: cursor + 8)
            let method = data.readUInt16(at: cursor + 10)
            let crc = data.readUInt32(at: cursor + 16)
            let compressedSize = Int(data.readUInt32(at: cursor + 20))
            let uncompressedSize = Int(data.readUInt32(at: cursor + 24))
            let nameLength = Int(data.readUInt16(at: cursor + 28))
            let extraLength = Int(data.readUInt16(at: cursor + 30))
            let commentLength = Int(data.readUInt16(at: cursor + 32))
            let localOffset = Int(data.readUInt32(at: cursor + 42))
            let nameStart = cursor + 46
            guard nameStart + nameLength <= data.count else {
                throw ZipStoreError.invalidArchive
            }
            let rawName = String(data: data.subdata(in: nameStart..<(nameStart + nameLength)), encoding: .utf8) ?? ""
            let path = normalizePath(rawName)
            cursor = nameStart + nameLength + extraLength + commentLength

            if path.isEmpty || path.hasSuffix("/") {
                continue
            }
            guard method == 0 else {
                throw ZipStoreError.unsupportedArchive
            }

            let payload = try readLocalFile(
                from: data,
                localOffset: localOffset,
                flags: flags,
                expectedSize: uncompressedSize == 0 ? compressedSize : uncompressedSize
            )
            if uncompressedSize > 0, payload.count != uncompressedSize {
                throw ZipStoreError.invalidArchive
            }
            if crc != 0, CRC32.hash(payload) != crc {
                throw ZipStoreError.invalidArchive
            }
            files[path] = payload
        }
        return files
    }

    /// Reads file bytes from a local header at `localOffset`.
    private static func readLocalFile(
        from data: Data,
        localOffset: Int,
        flags: UInt16,
        expectedSize: Int
    ) throws -> Data {
        guard localOffset + 30 <= data.count, data.readUInt32(at: localOffset) == 0x04034b50 else {
            throw ZipStoreError.invalidArchive
        }
        let nameLength = Int(data.readUInt16(at: localOffset + 26))
        let extraLength = Int(data.readUInt16(at: localOffset + 28))
        let dataStart = localOffset + 30 + nameLength + extraLength
        let sizeFromHeader = Int(data.readUInt32(at: localOffset + 18))
        let usesDescriptor = (flags & 0x0008) != 0
        let size = usesDescriptor ? expectedSize : (sizeFromHeader > 0 ? sizeFromHeader : expectedSize)
        guard dataStart >= 0, dataStart + size <= data.count else {
            throw ZipStoreError.invalidArchive
        }
        return data.subdata(in: dataStart..<(dataStart + size))
    }

    /// Scans backwards from EOF for the end-of-central-directory signature.
    private static func findEOCDOffset(in data: Data) -> Int? {
        let minimum = 22
        guard data.count >= minimum else { return nil }
        let maxComment = 65535
        let start = max(0, data.count - minimum - maxComment)
        var index = data.count - minimum
        while index >= start {
            if data.readUInt32(at: index) == 0x06054b50 {
                return index
            }
            index -= 1
        }
        return nil
    }

    /// Normalizes a ZIP path and rejects zip-slip / absolute paths.
    static func normalizePath(_ path: String) -> String {
        let trimmed = path.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = trimmed.split(separator: "/").map(String.init)
        guard !parts.contains(".."), !parts.contains(".") else {
            return ""
        }
        if trimmed.hasPrefix("/") { return "" }
        return parts.joined(separator: "/")
    }
}

/// Errors thrown while reading or writing a ZIP archive.
enum ZipStoreError: Error, LocalizedError {
    case invalidArchive
    case unsupportedArchive
    case pathTooLong(String)

    var errorDescription: String? {
        switch self {
        case .invalidArchive:
            "The zip archive is damaged or not a valid An AI Odyssey export."
        case .unsupportedArchive:
            "This zip uses compression or features that An AI Odyssey cannot read. Re-export from the app."
        case .pathTooLong(let path):
            "A file path in the archive is too long: \(path)"
        }
    }
}

// MARK: - Binary helpers

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        var little = value.littleEndian
        append(Data(bytes: &little, count: 2))
    }

    mutating func appendUInt32(_ value: UInt32) {
        var little = value.littleEndian
        append(Data(bytes: &little, count: 4))
    }

    func readUInt16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func readUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }
}

/// ZIP-compatible CRC-32 (IEEE).
private enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i in
        var crc = UInt32(i)
        for _ in 0..<8 {
            crc = (crc & 1) != 0 ? (0xEDB88320 ^ (crc >> 1)) : (crc >> 1)
        }
        return crc
    }

    static func hash(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}
