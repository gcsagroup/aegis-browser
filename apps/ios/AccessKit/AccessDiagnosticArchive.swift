import Foundation

/// Creates a single-file ZIP only after the user requests sharing.
public enum AccessDiagnosticArchive {
    public enum ArchiveError: Error { case emptyLog, tooLarge, cannotCreateFile }
    private static let folderPrefix = "aegis-access-share-"

    /// Runs once before this process can create an active share. Activity
    /// completion is not delivered when iOS terminates the previous process.
    public static let recoveredTemporaryArchives: Bool = {
        do {
            try removeAbandonedTemporaryArchives(in: FileManager.default.temporaryDirectory)
            return true
        } catch {
            return false
        }
    }()

    static func removeAbandonedTemporaryArchives(in directory: URL) throws {
        let manager = FileManager.default
        for folder in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let name = folder.lastPathComponent
            guard name.hasPrefix(folderPrefix),
                  UUID(uuidString: String(name.dropFirst(folderPrefix.count))) != nil else { continue }
            try manager.removeItem(at: folder)
        }
    }

    public static func createTemporary(snapshot: String) throws -> URL {
        guard recoveredTemporaryArchives else { throw ArchiveError.cannotCreateFile }
        let input = Data(snapshot.utf8)
        guard !input.isEmpty else { throw ArchiveError.emptyLog }
        guard input.count <= Int(UInt32.max) else { throw ArchiveError.tooLarge }
        let compressed = try (input as NSData).compressed(using: .zlib) as Data
        guard compressed.count <= Int(UInt32.max) else { throw ArchiveError.tooLarge }
        let name = Data("access-diagnostics.log".utf8)
        let crc = crc32(input)
        var zip = Data()
        zip.appendLE(UInt32(0x04034b50)); zip.appendLE(UInt16(20)); zip.appendLE(UInt16(0))
        zip.appendLE(UInt16(8)); zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0))
        zip.appendLE(crc); zip.appendLE(UInt32(compressed.count)); zip.appendLE(UInt32(input.count))
        zip.appendLE(UInt16(name.count)); zip.appendLE(UInt16(0)); zip.append(name); zip.append(compressed)
        let centralOffset = UInt32(zip.count)
        zip.appendLE(UInt32(0x02014b50)); zip.appendLE(UInt16(20)); zip.appendLE(UInt16(20))
        zip.appendLE(UInt16(0)); zip.appendLE(UInt16(8)); zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0))
        zip.appendLE(crc); zip.appendLE(UInt32(compressed.count)); zip.appendLE(UInt32(input.count))
        zip.appendLE(UInt16(name.count)); zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0))
        zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0)); zip.appendLE(UInt32(0)); zip.appendLE(UInt32(0)); zip.append(name)
        let centralSize = UInt32(zip.count) - centralOffset
        zip.appendLE(UInt32(0x06054b50)); zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0))
        zip.appendLE(UInt16(1)); zip.appendLE(UInt16(1)); zip.appendLE(centralSize); zip.appendLE(centralOffset); zip.appendLE(UInt16(0))

        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent(folderPrefix + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            var protectedFolder = folder
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try protectedFolder.setResourceValues(values)
            let file = folder.appendingPathComponent("aegis-access-diagnostics.zip")
            var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
            #if os(iOS)
            attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
            #endif
            guard manager.createFile(atPath: file.path, contents: nil, attributes: attributes) else {
                throw ArchiveError.cannotCreateFile
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.write(contentsOf: zip)
            return file
        } catch {
            try? manager.removeItem(at: folder)
            throw error
        }
    }

    public static func removeTemporary(_ file: URL) {
        let folder = file.deletingLastPathComponent()
        guard folder.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL,
              folder.lastPathComponent.hasPrefix(folderPrefix) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb8_8320 : 0) }
        }
        return ~crc
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
