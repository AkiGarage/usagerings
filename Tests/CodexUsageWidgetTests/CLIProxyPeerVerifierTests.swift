import Darwin
import XCTest
@testable import CodexUsageWidget

final class CLIProxyPeerVerifierTests: XCTestCase {
    func testRealVerifierRejectsPortWithoutListener() throws {
        let (fd, port) = try boundSocket()
        defer { close(fd) }
        // Keep the ephemeral port reserved without calling listen(), avoiding a free-port race.
        XCTAssertFalse(LibprocCLIProxyPeerVerifier(port: port).isTrustedListener())
    }

    func testRealVerifierRejectsCurrentUsersUnrelatedExecutable() throws {
        let (fd, port) = try boundSocket()
        defer { close(fd) }
        XCTAssertEqual(listen(fd, 1), 0)
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        XCTAssertEqual(proc_pidfdinfo(getpid(), fd, PROC_PIDFDSOCKETINFO, &info, size), size)
        XCTAssertTrue(LibprocCLIProxyPeerVerifier.isListener(info.psi, port: port))
        XCTAssertFalse(LibprocCLIProxyPeerVerifier(port: port).isTrustedListener())
    }

    func testExecutableMustHaveExactBasenameFromAbsolutePath() {
        for path in ["/opt/homebrew/opt/cliproxyapi/bin/cliproxyapi",
                     "/opt/homebrew/Cellar/cliproxyapi/1.2.3/bin/cliproxyapi",
                     "/usr/local/bin/cliproxyapi"] {
            XCTAssertTrue(LibprocCLIProxyPeerVerifier.isExpectedExecutable(path))
        }
        for path in ["", "cliproxyapi", "/tmp/cliproxyapi-fake", "/tmp/cliproxyapi/python3"] {
            XCTAssertFalse(LibprocCLIProxyPeerVerifier.isExpectedExecutable(path))
        }
    }

    func testProcessIdentityRequiresSamePIDAndStartTime() {
        var original = proc_bsdinfo()
        original.pbi_pid = 123
        original.pbi_start_tvsec = 100
        original.pbi_start_tvusec = 200
        XCTAssertTrue(LibprocCLIProxyPeerVerifier.isSameProcess(original, original))
        var otherPID = original
        otherPID.pbi_pid += 1
        var reusedPID = original
        reusedPID.pbi_start_tvsec += 1
        var reusedWithinSecond = original
        reusedWithinSecond.pbi_start_tvusec += 1
        for changed in [otherPID, reusedPID, reusedWithinSecond] {
            XCTAssertFalse(LibprocCLIProxyPeerVerifier.isSameProcess(original, changed))
        }
    }

    func testLoopbackAndWildcardTCPListenersMatchRequestedPort() {
        var info = listener()
        XCTAssertTrue(LibprocCLIProxyPeerVerifier.isListener(info, port: 8317))
        XCTAssertFalse(LibprocCLIProxyPeerVerifier.isListener(info, port: 8318))
        info.soi_proto.pri_tcp.tcpsi_ini.insi_laddr.ina_46.i46a_addr4.s_addr = INADDR_ANY
        XCTAssertTrue(LibprocCLIProxyPeerVerifier.isListener(info, port: 8317))
    }

    func testOtherAddressesNonTCPAndNonListeningSocketsDoNotMatch() {
        var otherAddress = listener()
        otherAddress.soi_proto.pri_tcp.tcpsi_ini.insi_laddr.ina_46.i46a_addr4.s_addr = UInt32(0x7f000002).bigEndian
        var established = listener()
        established.soi_proto.pri_tcp.tcpsi_state = TSI_S_ESTABLISHED
        var udp = listener()
        udp.soi_kind = Int32(SOCKINFO_IN)
        udp.soi_type = SOCK_DGRAM
        udp.soi_protocol = IPPROTO_UDP
        var unix = listener()
        unix.soi_family = AF_UNIX
        for info in [otherAddress, established, udp, unix] {
            XCTAssertFalse(LibprocCLIProxyPeerVerifier.isListener(info, port: 8317))
        }
    }

    func testIPv6OnlyListenerCannotAuthorizeIPv4Request() {
        var info = listener()
        info.soi_family = AF_INET6
        info.soi_proto.pri_tcp.tcpsi_ini.insi_laddr.ina_46.i46a_addr4.s_addr = INADDR_ANY
        info.soi_proto.pri_tcp.tcpsi_ini.insi_vflag = UInt8(INI_IPV4 | INI_IPV6)
        XCTAssertTrue(LibprocCLIProxyPeerVerifier.isListener(info, port: 8317))
        info.soi_proto.pri_tcp.tcpsi_ini.insi_vflag = UInt8(INI_IPV6)
        XCTAssertFalse(LibprocCLIProxyPeerVerifier.isListener(info, port: 8317))
    }

    private func listener() -> socket_info {
        var info = socket_info()
        info.soi_kind = Int32(SOCKINFO_TCP)
        info.soi_type = SOCK_STREAM
        info.soi_protocol = IPPROTO_TCP
        info.soi_family = AF_INET
        info.soi_proto.pri_tcp.tcpsi_state = TSI_S_LISTEN
        info.soi_proto.pri_tcp.tcpsi_ini.insi_vflag = UInt8(INI_IPV4)
        info.soi_proto.pri_tcp.tcpsi_ini.insi_lport = Int32(UInt16(8317).bigEndian)
        info.soi_proto.pri_tcp.tcpsi_ini.insi_laddr.ina_46.i46a_addr4.s_addr = INADDR_LOOPBACK.bigEndian
        return info
    }

    private func boundSocket() throws -> (Int32, UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var succeeded = false
        defer { if !succeeded { close(fd) } }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw POSIXError(.EIO) }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        guard named == 0 else { throw POSIXError(.EIO) }
        succeeded = true
        return (fd, UInt16(bigEndian: address.sin_port))
    }
}
