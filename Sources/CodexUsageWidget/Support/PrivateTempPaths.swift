import Foundation

/// Per-user scratch location for diagnostics and secondary snapshot copies.
///
/// Uses the macOS per-user temporary directory (`/var/folders/.../T`), never the
/// shared `/private/tmp`, and keeps an app subdirectory at mode 0700 with files
/// at 0600 so other local accounts cannot read usage data.
enum PrivateTempPaths {
    static let directoryName = "UsageRings"

    static func directory(base: URL = FileManager.default.temporaryDirectory,
                          fileManager: FileManager = .default) -> URL? {
        let url = base.appendingPathComponent(directoryName, isDirectory: true)
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        } catch {
            return nil
        }
    }

    static func file(_ name: String, base: URL = FileManager.default.temporaryDirectory) -> URL? {
        directory(base: base)?.appendingPathComponent(name)
    }

    /// URL for a subdirectory path without creating it (callers create with 0700).
    static func unresolvedFile(_ components: String...) -> URL {
        components.reduce(FileManager.default.temporaryDirectory
            .appendingPathComponent(directoryName, isDirectory: true)) { $0.appendingPathComponent($1) }
    }

    static func writePrivately(_ data: Data, to url: URL) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func appendPrivately(_ data: Data, to url: URL) {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } else {
            writePrivately(data, to: url)
        }
    }
}
