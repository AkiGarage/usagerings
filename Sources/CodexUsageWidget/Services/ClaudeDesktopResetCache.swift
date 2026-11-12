import CryptoKit
import Darwin
import Foundation
import UsageRingsZstd

/// Claude reset tickets as Claude Desktop last saw them, read out of its Chromium HTTP cache.
///
/// Claude's OAuth usage endpoint answers `cedar_ember` with `ineligible_reason: "surface"`, so the
/// only place the real grants appear is the response Desktop's Settings → Usage page fetched:
/// `GET https://claude.ai/api/organizations/<org>/usage?cedar_ember=1&skip_spend=1`. Chromium keeps
/// it in `Cache_Data/<hash>_0`, zstd-compressed. Approach after Codenotch's
/// `ClaudeDesktopUsageCache.swift` (MIT).
///
/// Bounded by construction: the directory is never listed. Chromium's Simple Cache names an entry
/// after the first eight bytes of the SHA-1 of its key, so for one organization this opens at most
/// `keys(organization:)` files. No token, cookie, keychain item, network request or write.
/// Every failure is nil, and nil is "unknown", never "zero tickets".
struct ClaudeDesktopResetCache: Sendable {
    struct Reading: Equatable, Sendable {
        let outcome: ClaudeResetGrantsOutcome
        /// The response's own `Date:` (else the entry's mtime): when the grants were true, not now.
        let observedAt: Date
    }

    let directory: URL

    static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/Cache/Cache_Data", isDirectory: true)

    static let maxEntryBytes = 512 * 1024
    static let maxDecompressedBytes = 256 * 1024
    static let maxKeyBytes = 8 * 1024
    static let maxConfigBytes = 32 * 1024 * 1024
    /// A capture dated further ahead than this is a clock problem, not a reading.
    static let futureTolerance: TimeInterval = 30 * 60
    static let headerBytes = 24
    private static let entryMagic: UInt64 = 0xfcfb_6d1b_a772_5c30
    private static let zstdMagic: [UInt8] = [0x28, 0xb5, 0x2f, 0xfd]

    init(directory: URL = ClaudeDesktopResetCache.defaultDirectory) {
        self.directory = directory
    }

    /// The cache keys Desktop uses for the reset-carrying usage request. Only the `cedar_ember=1`
    /// variants: the plain usage keys always carry a null block and say nothing about grants.
    static func keys(organization: String) -> [String] {
        ["cedar_ember=1&skip_spend=1", "cedar_ember=1"].map {
            "1/0/https://claude.ai/api/organizations/\(organization)/usage?\($0)"
        }
    }

    /// `%016llx_0` of the little-endian first eight bytes of SHA-1(key), as Chromium names it.
    static func entryFileName(forKey key: String) -> String {
        let digest = Array(Insecure.SHA1.hash(data: Data(key.utf8)))
        var hash: UInt64 = 0
        for index in (0..<8).reversed() { hash = hash << 8 | UInt64(digest[index]) }
        return String(format: "%016llx_0", hash)
    }

    /// Lower-cased organization UUID, or nil when `raw` is not one.
    static func normalizedOrganization(_ raw: String) -> String? {
        let value = raw.lowercased()
        guard value.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                          options: .regularExpression) != nil else { return nil }
        return value
    }

    /// `oauthAccount.organizationUuid` of one Claude Code login. `configDir` nil is the default login,
    /// whose state file is `~/.claude.json`; otherwise `$CLAUDE_CONFIG_DIR/.claude.json`.
    static func organization(configDir: String?, home: String = NSHomeDirectory()) -> String? {
        let path = (configDir ?? home) + "/.claude.json"
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxConfigBytes + 1), data.count <= maxConfigBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = object["oauthAccount"] as? [String: Any],
              let raw = account["organizationUuid"] as? String else { return nil }
        return normalizedOrganization(raw)
    }

    /// The newest reset response cached for `organization`, or nil.
    ///
    /// Only the most recently written candidate is believed. If it cannot be decoded (Chromium
    /// rewriting it, a format change) the answer is nil, never an older entry: an older entry may
    /// hold tickets that a newer response already spent.
    func reading(organization raw: String, now: Date) -> Reading? {
        guard let organization = Self.normalizedOrganization(raw) else { return nil }
        let candidates = Self.keys(organization: organization).compactMap { key -> (key: String, bytes: [UInt8], modified: Date)? in
            let url = directory.appendingPathComponent(Self.entryFileName(forKey: key), isDirectory: false)
            guard let file = Self.contents(of: url) else { return nil }
            return (key, file.bytes, file.modified)
        }
        guard let newest = candidates.max(by: { $0.modified < $1.modified }),
              let parsed = Self.parse(entry: newest.bytes),
              parsed.key == newest.key
        else { return nil }
        let observedAt = parsed.date ?? newest.modified
        guard observedAt.timeIntervalSince(now) < Self.futureTolerance else { return nil }
        return Reading(outcome: ClaudeResetGrantsClient.parse(parsed.body), observedAt: observedAt)
    }

    /// Bytes and mtime from one descriptor, bounded. A read, not a map: Chromium truncates these
    /// files underneath readers, and a mapped page going away is SIGBUS.
    private static func contents(of url: URL) -> (bytes: [UInt8], modified: Date)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > headerBytes, info.st_size <= maxEntryBytes,
              let data = try? handle.read(upToCount: maxEntryBytes) else { return nil }
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                            + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        return ([UInt8](data), modified)
    }

    struct Parsed: Equatable {
        let key: String
        let body: Data
        let date: Date?
    }

    /// Key, decompressed body and `Date:` of one Simple Cache entry (header | key | body | headers).
    static func parse(entry: [UInt8]) -> Parsed? {
        guard let key = key(in: entry) else { return nil }
        let bodyStart = headerBytes + key.utf8.count
        guard entry.count - bodyStart > zstdMagic.count,
              Array(entry[bodyStart..<(bodyStart + zstdMagic.count)]) == zstdMagic else { return nil }
        let frame = Array(entry[bodyStart...])
        guard let (body, frameSize) = decompress(frame) else { return nil }
        return Parsed(key: key, body: body, date: httpDate(inTrailer: Array(frame[frameSize...])))
    }

    static func key(in entry: [UInt8]) -> String? {
        guard entry.count > headerBytes, readUInt64(entry, at: 0) == entryMagic else { return nil }
        let length = Int(readUInt32(entry, at: 12))
        guard length > 0, length <= maxKeyBytes, headerBytes + length <= entry.count else { return nil }
        return String(bytes: entry[headerBytes..<(headerBytes + length)], encoding: .utf8)
    }

    /// The `date:` header from the NUL-separated header block Chromium stores after the body.
    static func httpDate(inTrailer trailer: [UInt8]) -> Date? {
        for name in ["date:", "Date:"] {
            let needle: [UInt8] = [0] + Array(name.utf8)
            guard let start = firstIndex(of: needle, in: trailer) else { continue }
            let valueStart = start + needle.count
            guard let end = trailer[valueStart...].firstIndex(of: 0),
                  let text = String(bytes: trailer[valueStart..<end], encoding: .utf8),
                  let date = httpDateFormatter.date(from: text.trimmingCharacters(in: .whitespaces))
            else { continue }
            return date
        }
        return nil
    }

    /// The zstd frame at the start of `bytes`, capped at `maxDecompressedBytes` by the decoder itself.
    private static func decompress(_ bytes: [UInt8]) -> (Data, Int)? {
        bytes.withUnsafeBytes { source -> (Data, Int)? in
            let compressed = ZSTD_findFrameCompressedSize(source.baseAddress, source.count)
            guard ZSTD_isError(compressed) == 0, compressed > 0, compressed <= source.count else { return nil }
            let declared = ZSTD_getFrameContentSize(source.baseAddress, source.count)
            if declared != ZSTD_CONTENTSIZE_UNKNOWN, declared != ZSTD_CONTENTSIZE_ERROR,
               declared > UInt64(maxDecompressedBytes) { return nil }
            var output = [UInt8](repeating: 0, count: maxDecompressedBytes)
            let written = output.withUnsafeMutableBytes {
                ZSTD_decompress($0.baseAddress, $0.count, source.baseAddress, compressed)
            }
            guard ZSTD_isError(written) == 0, written > 0, written <= output.count else { return nil }
            return (Data(output[0..<written]), compressed)
        }
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reversed().reduce(UInt32(0)) { $0 << 8 | UInt32(bytes[offset + $1]) }
    }

    private static func readUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        (0..<8).reversed().reduce(UInt64(0)) { $0 << 8 | UInt64(bytes[offset + $1]) }
    }

    private static func firstIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count)
        where haystack[start..<(start + needle.count)].elementsEqual(needle) { return start }
        return nil
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}
