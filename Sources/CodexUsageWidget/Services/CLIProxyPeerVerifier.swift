import Darwin
import Foundation

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
        return Self.isExpectedExecutable(String(cString: path))
    }

    static func isSameProcess(_ before: proc_bsdinfo, _ after: proc_bsdinfo) -> Bool {
        before.pbi_pid == after.pbi_pid && before.pbi_start_tvsec == after.pbi_start_tvsec
            && before.pbi_start_tvusec == after.pbi_start_tvusec
    }

    static func isExpectedExecutable(_ path: String) -> Bool {
        path.hasPrefix("/") && (path as NSString).lastPathComponent == "cliproxyapi"
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
