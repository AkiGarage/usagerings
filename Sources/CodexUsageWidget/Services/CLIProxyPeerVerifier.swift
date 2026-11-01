import Darwin
import Foundation
import Security

protocol CLIProxyPeerVerifier: Sendable {
    func isTrustedListener() -> Bool
}

/// A fresh libproc snapshot, never a cached process-name or shell-command lookup.
struct LibprocCLIProxyPeerVerifier: CLIProxyPeerVerifier {
    let port: UInt16

    init(port: UInt16 = 8317) {
        self.port = port
    }

    func isTrustedListener() -> Bool {
        guard port != 0 else { return false }
        let estimatedCount = proc_listallpids(nil, 0)
        guard estimatedCount > 0 else { return false }
        var pids = [pid_t](repeating: 0, count: Int(estimatedCount) + 32)
        let pidBytes = Int32(pids.count * MemoryLayout<pid_t>.stride)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, pidBytes) }
        guard count > 0, count < pids.count else { return false }

        var found = false
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var process = proc_bsdinfo()
            let processSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &process, processSize) == processSize else { continue }
            let fdBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            let stride = MemoryLayout<proc_fdinfo>.stride
            guard fdBytes > 0, Int(fdBytes) % stride == 0 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(fdBytes) / stride + 16)
            let capacity = Int32(fds.count * stride)
            let copied = fds.withUnsafeMutableBytes {
                proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, capacity)
            }
            guard copied > 0 else { continue } // The process may have exited or be inaccessible.
            guard copied < capacity, Int(copied) % stride == 0 else { return false }
            for fd in fds.prefix(Int(copied) / stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
                var info = socket_fdinfo()
                let size = Int32(MemoryLayout<socket_fdinfo>.size)
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                      Self.isListener(info.psi, port: port) else { continue }
                guard isExpectedProcess(pid, original: process) else { return false }
                found = true
            }
        }
        return found
    }

    private func isExpectedProcess(_ pid: pid_t, original: proc_bsdinfo) -> Bool {
        // PROC_PIDPATHINFO_MAXSIZE is (4 * MAXPATHLEN), a macro Swift cannot import.
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathSize = UInt32(path.count)
        let length = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, pathSize) }
        guard length > 0, length < path.count else { return false }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        // Bracket the socket/path reads so PID reuse cannot mix different processes' evidence.
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              Self.isSameProcess(original, info),
              info.pbi_uid == getuid(), info.pbi_ruid == getuid() else { return false }
        // proc_pidpath supplies the executable path, not an argv/process-name alias.
        // UR-01: a same-user process merely *named* cliproxyapi is not enough. Require a known
        // install location, a file not writable by other users, and a valid code signature on
        // the running process (Homebrew builds are ad-hoc signed, so no team ID is required).
        let executable = String(cString: path)
        guard Self.isExpectedExecutable(executable, configuredPath: Self.configuredExecutablePath()),
              Self.hasSafeOwnership(executable),
              Self.hasValidCodeSignature(pid: pid) else { return false }
        return true
    }

    /// Optional override for non-standard installs: `defaults write <bundle> CLIProxyExecutablePath /abs/path`.
    static func configuredExecutablePath() -> String? {
        guard let value = UserDefaults.standard.string(forKey: "CLIProxyExecutablePath"),
              !value.isEmpty else { return nil }
        return value
    }

    /// Homebrew (Apple Silicon and Intel) and the conventional /usr/local/bin install.
    static let allowedExactPaths: Set<String> = [
        "/opt/homebrew/opt/cliproxyapi/bin/cliproxyapi",
        "/opt/homebrew/bin/cliproxyapi",
        "/usr/local/opt/cliproxyapi/bin/cliproxyapi",
        "/usr/local/bin/cliproxyapi",
    ]
    static let allowedCellarRoots = ["/opt/homebrew/Cellar/cliproxyapi/", "/usr/local/Cellar/cliproxyapi/"]

    static func isExpectedExecutable(_ path: String, configuredPath: String? = nil) -> Bool {
        guard path.hasPrefix("/"), (path as NSString).lastPathComponent == "cliproxyapi" else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
        if let configuredPath, configuredPath.hasPrefix("/"), path == configuredPath { return true }
        if allowedExactPaths.contains(path) { return true }
        for root in allowedCellarRoots where path.hasPrefix(root) {
            // Exactly <root><version>/bin/cliproxyapi
            let rest = path.dropFirst(root.count).split(separator: "/", omittingEmptySubsequences: false)
            if rest.count == 3, !rest[0].isEmpty, rest[1] == "bin", rest[2] == "cliproxyapi" { return true }
        }
        return false
    }

    /// The binary must be owned by this user or root and not writable by group/others.
    static func hasSafeOwnership(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return false }
        guard st.st_uid == getuid() || st.st_uid == 0 else { return false }
        return st.st_mode & (S_IWGRP | S_IWOTH) == 0
    }

    /// Validates the *running* code (dynamic check), so a binary swapped or patched after launch fails.
    static func hasValidCodeSignature(pid: pid_t) -> Bool {
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else { return false }
        return SecCodeCheckValidity(code, [], nil) == errSecSuccess
    }

    static func isSameProcess(_ before: proc_bsdinfo, _ after: proc_bsdinfo) -> Bool {
        before.pbi_pid == after.pbi_pid && before.pbi_start_tvsec == after.pbi_start_tvsec
            && before.pbi_start_tvusec == after.pbi_start_tvusec
    }

    static func isListener(_ socket: socket_info, port: UInt16) -> Bool {
        guard socket.soi_kind == SOCKINFO_TCP, socket.soi_type == SOCK_STREAM,
              socket.soi_protocol == IPPROTO_TCP,
              socket.soi_family == AF_INET || socket.soi_family == AF_INET6 else { return false }
        let tcp = socket.soi_proto.pri_tcp
        let inet = tcp.tcpsi_ini
        guard tcp.tcpsi_state == TSI_S_LISTEN, inet.insi_vflag & UInt8(INI_IPV4) != 0,
              UInt16(bigEndian: UInt16(truncatingIfNeeded: inet.insi_lport)) == port else { return false }
        let address = UInt32(bigEndian: inet.insi_laddr.ina_46.i46a_addr4.s_addr)
        // Wildcard listeners also accept 127.0.0.1, including IPv4-capable dual-stack sockets.
        return address == INADDR_LOOPBACK || address == INADDR_ANY
    }
}
