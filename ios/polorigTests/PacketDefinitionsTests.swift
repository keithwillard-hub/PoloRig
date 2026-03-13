import XCTest
@testable import PoloRig

final class PacketDefinitionsTests: XCTestCase {

    // MARK: - Packet Sizes

    func testPacketSize_control_is16() {
        XCTAssertEqual(PacketSize.control, 0x10)
        XCTAssertEqual(PacketSize.control, 16)
    }

    func testPacketSize_ping_is21() {
        XCTAssertEqual(PacketSize.ping, 0x15)
        XCTAssertEqual(PacketSize.ping, 21)
    }

    func testPacketSize_openClose_is22() {
        XCTAssertEqual(PacketSize.openClose, 0x16)
        XCTAssertEqual(PacketSize.openClose, 22)
    }

    func testPacketSize_token_is64() {
        XCTAssertEqual(PacketSize.token, 0x40)
        XCTAssertEqual(PacketSize.token, 64)
    }

    func testPacketSize_login_is128() {
        XCTAssertEqual(PacketSize.login, 0x80)
        XCTAssertEqual(PacketSize.login, 128)
    }

    func testPacketSize_connInfo_is144() {
        XCTAssertEqual(PacketSize.connInfo, 0x90)
        XCTAssertEqual(PacketSize.connInfo, 144)
    }

    func testPacketSize_capabilities_is168() {
        XCTAssertEqual(PacketSize.capabilities, 0xA8)
        XCTAssertEqual(PacketSize.capabilities, 168)
    }

    func testPacketSize_civHeader_is21() {
        XCTAssertEqual(PacketSize.civHeader, 0x15)
        XCTAssertEqual(PacketSize.civHeader, 21)
    }

    // MARK: - Control Header Offsets Don't Overlap

    func testControlOffsets_noOverlap() {
        let offsets: [(name: String, start: Int, size: Int)] = [
            ("length", ControlOffset.length, 4),
            ("type", ControlOffset.type, 2),
            ("sequence", ControlOffset.sequence, 2),
            ("sendId", ControlOffset.sendId, 4),
            ("recvId", ControlOffset.recvId, 4),
        ]
        for i in 0..<offsets.count {
            for j in (i+1)..<offsets.count {
                let a = offsets[i]
                let b = offsets[j]
                let aEnd = a.start + a.size
                let bEnd = b.start + b.size
                let overlaps = a.start < bEnd && b.start < aEnd
                XCTAssertFalse(overlaps, "\(a.name) [\(a.start)..<\(aEnd)] overlaps \(b.name) [\(b.start)..<\(bEnd)]")
            }
        }
    }

    func testControlHeader_fitsIn16Bytes() {
        // Last field: recvId at 0x0C, 4 bytes → ends at 0x10 = 16
        XCTAssertEqual(ControlOffset.recvId + 4, Int(PacketSize.control))
    }

    // MARK: - Login Offsets

    func testLoginOffsets_withinLoginSize() {
        XCTAssertTrue(LoginOffset.userName + 16 <= Int(PacketSize.login))
        XCTAssertTrue(LoginOffset.password + 16 <= Int(PacketSize.login))
        XCTAssertTrue(LoginOffset.computer + 16 <= Int(PacketSize.login))
    }

    func testLoginOffsets_noOverlap() {
        // userName=0x40, password=0x50, computer=0x60 — each 16 bytes
        XCTAssertEqual(LoginOffset.userName + 16, LoginOffset.password)
        XCTAssertEqual(LoginOffset.password + 16, LoginOffset.computer)
    }

    // MARK: - Timing Constants

    func testTimingConstants_positive() {
        XCTAssertGreaterThan(Timing.pingInterval, 0)
        XCTAssertGreaterThan(Timing.idleInterval, 0)
        XCTAssertGreaterThan(Timing.resendInterval, 0)
        XCTAssertGreaterThan(Timing.tokenRenewInterval, 0)
    }

    func testTimingConstants_reasonable() {
        // Ping should be 1-10 seconds
        XCTAssertGreaterThanOrEqual(Timing.pingInterval, 1.0)
        XCTAssertLessThanOrEqual(Timing.pingInterval, 10.0)

        // Token renewal should be >= 30 seconds
        XCTAssertGreaterThanOrEqual(Timing.tokenRenewInterval, 30.0)
    }

    // MARK: - Packet Types

    func testPacketTypes_uniqueValues() {
        let types: [UInt16] = [
            PacketType.idle,
            PacketType.retransmit,
            PacketType.areYouThere,
            PacketType.iAmHere,
            PacketType.disconnect,
            PacketType.areYouReady,
            PacketType.ping,
        ]
        let unique = Set(types)
        XCTAssertEqual(unique.count, types.count, "Packet types contain duplicates")
    }

    // MARK: - CredentialCodec Key

    func testCredentialCodec_keyLength() {
        XCTAssertEqual(CredentialCodec.encodeKey.count, 95)
        // 95 = printable ASCII range (0x20-0x7E)
    }

    func testCredentialCodec_keyHasNoDuplicates() {
        let unique = Set(CredentialCodec.encodeKey)
        XCTAssertEqual(unique.count, CredentialCodec.encodeKey.count, "Encode key has duplicate values")
    }

    // MARK: - CIV Packet Offsets

    func testCIVPacketOffset_dataStartsAfterHeader() {
        XCTAssertEqual(CIVPacketOffset.data, Int(PacketSize.civHeader))
    }

    // MARK: - OpenClose Offsets

    func testOpenCloseOffsets_withinSize() {
        XCTAssertTrue(OpenCloseOffset.request + 1 <= Int(PacketSize.openClose))
    }

    // MARK: - ConnInfo Offsets

    func testConnInfoOffsets_withinSize() {
        XCTAssertTrue(ConnInfoOffset.convert + 1 <= Int(PacketSize.connInfo))
    }
}
