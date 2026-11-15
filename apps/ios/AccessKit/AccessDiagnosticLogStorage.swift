import Foundation

/// Serial file access for already-filtered diagnostic records.
final class AccessDiagnosticLogStorage: @unchecked Sendable {
    static let maximumRecords = 8192
    enum StorageError: Error { case invalidHistory, unsafePath, tooLarge }
    private struct History: Codable { let version: Int; let lines: [String] }
    private let queue: DispatchQueue
    let directory: URL
    var file: URL { directory.appendingPathComponent("history.json") }
    private let maximumFileBytes = 1024 * 1024

    init(directory: URL, queue: DispatchQueue = DispatchQueue(label: "aegis.access.diagnostics.disk", qos: .utility)) {
        self.directory = directory
        self.queue = queue
    }

    func load(_ completion: @escaping @Sendable (Result<[String], Error>) -> Void) {
        queue.async {
            completion(Result {
                guard FileManager.default.fileExists(atPath: self.file.path) else { return [] }
                try self.checkPath(self.directory, directory: true)
                try self.checkPath(self.file, directory: false)
                let handle = try FileHandle(forReadingFrom: self.file)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: self.maximumFileBytes + 1) ?? Data()
                guard data.count <= self.maximumFileBytes else { throw StorageError.tooLarge }
                let history = try JSONDecoder().decode(History.self, from: data)
                guard history.version == 1, history.lines.count <= Self.maximumRecords,
                      history.lines.allSatisfy({ line in
                          !line.isEmpty && line.utf8.count <= 16 * 1024 &&
                          line.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
                      }) else { throw StorageError.invalidHistory }
                return history.lines
            })
        }
    }

    func save(_ lines: [String], completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        queue.async {
            completion(Result {
                guard lines.count <= Self.maximumRecords else { throw StorageError.tooLarge }
                let manager = FileManager.default
                if manager.fileExists(atPath: self.directory.path) { try self.checkPath(self.directory, directory: true) }
                try manager.createDirectory(at: self.directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
                try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.directory.path)
                var folder = self.directory
                var resource = URLResourceValues(); resource.isExcludedFromBackup = true
                try folder.setResourceValues(resource)
                if manager.fileExists(atPath: self.file.path) { try self.checkPath(self.file, directory: false) }
                let data = try JSONEncoder().encode(History(version: 1, lines: lines))
                guard data.count <= self.maximumFileBytes else { throw StorageError.tooLarge }
                #if os(iOS)
                try data.write(to: self.file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                #else
                try data.write(to: self.file, options: .atomic)
                #endif
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.file.path)
            })
        }
    }

    func clear(_ completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        queue.async {
            completion(Result {
                guard FileManager.default.fileExists(atPath: self.directory.path) else { return }
                try self.checkPath(self.directory, directory: true)
                // Includes any atomic-write temporary files left by an interrupted write.
                try FileManager.default.removeItem(at: self.directory)
            })
        }
    }

    private func checkPath(_ url: URL, directory: Bool) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        guard values.isSymbolicLink != true,
              directory ? values.isDirectory == true : values.isRegularFile == true else { throw StorageError.unsafePath }
    }
}
