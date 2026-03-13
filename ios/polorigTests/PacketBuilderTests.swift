import XCTest
@testable import PoloRig

final class PacketBuilderTests: XCTestCase {

    // MARK: - AreYouThere Packet

    func testAreYouThere_size() {
        let packet = PacketBuilder.areYouThere(sendId: 0x12345678)
        XCTAssertEqual(packet.count, 16)
    }

    func testAreYouThere_length_field() {
        let packet = PacketBuilder.areYouThere(sendId: 0x12345678)
        XCTAssertEqual(packet.readUInt32(at: ControlOffset.length), PacketSize.control)
    }

    func testAreYouThere_type() {
        let packet = PacketBuilder.areYouThere(sendId: 0x12345678)
        XCTAssertEqual(packet.readUInt16(at: ControlOffset.type), PacketType.areYouThere)
    }

    func testAreYouThere_sendId() {
        let packet = PacketBuilder.areYouThere(sendId: 0x12345678)
        XCTAssertEqual(packet.readUInt32(at: ControlOffset.sendId), 0x12345678)
    }

    func testAreYouThere_recvId_zero() {
        let packet = PacketBuilder.areYouThere(sendId: 0x12345678)
        XCTAssertEqual(packet.readUInt32(at: ControlOffset.recvId), 0)
    }

    func testAreYouThere_sequence_zero() {
        let packet = PacketBuilder.areYouThere(sendId: 0x12345678)
        XCTAssertEqual(packet.readUInt16(at: ControlOffset.sequence), 0)
    }

    // MARK: - Ping Packet

    func testPing_size() {
        let packet = PacketBuilder.ping(
            sequence: 1, sendId: 100, recvId: 200,
            isReply: false, dataA: 0x1234, dataB: 0x5678
        )
        XCTAssertEqual(packet.count, 21)
    }

    func testPing_request_flag() {
        let request = PacketBuilder.ping(
            sequence: 1, sendId: 100, recvId: 200,
            isReply: false, dataA: 0, dataB: 0
        )
        XCTAssertEqual(request[PingOffset.request], 0x00)

        let reply = PacketBuilder.ping(
            sequence: 1, sendId: 100, recvId: 200,
            isReply: true, dataA: 0, dataB: 0
        )
        XCTAssertEqual(reply[PingOffset.request], 0x01)
    }

    func testPing_dataFields() {
        let packet = PacketBuilder.ping(
            sequence: 1, sendId: 100, recvId: 200,
            isReply: false, dataA: 0x1234, dataB: 0x5678
        )
        XCTAssertEqual(packet.readUInt16(at: PingOffset.dataA), 0x1234)
        XCTAssertEqual(packet.readUInt16(at: PingOffset.dataB), 0x5678)
    }

    // MARK: - PongReply

    func testPongReply_swapsIds() {
        let ping = PacketBuilder.ping(
            sequence: 5, sendId: 100, recvId: 200,
            isReply: false, dataA: 0x1111, dataB: 0x2222
        )
        let pong = PacketBuilder.pongReply(from: ping, sendId: 300, recvId: 400)
        XCTAssertEqual(pong.readUInt32(at: ControlOffset.sendId), 300)
        XCTAssertEqual(pong.readUInt32(at: ControlOffset.recvId), 400)
        XCTAssertEqual(pong[PingOffset.request], 0x01)
    }

    // MARK: - Login Packet

    func testLogin_size() {
        let packet = PacketBuilder.login(
            innerSeq: 1, sendId: 100, recvId: 200,
            sequence: 3, tokReq: 1,
            userName: "testuser", password: "testpass",
            computerName: "MyMac"
        )
        XCTAssertEqual(packet.count, 128)
    }

    func testLogin_length_field() {
        let packet = PacketBuilder.login(
            innerSeq: 1, sendId: 100, recvId: 200,
            sequence: 3, tokReq: 1,
            userName: "testuser", password: "testpass",
            computerName: "MyMac"
        )
        XCTAssertEqual(packet.readUInt32(at: ControlOffset.length), PacketSize.login)
    }

    func testLogin_code_is_loginRequest() {
        let packet = PacketBuilder.login(
            innerSeq: 1, sendId: 100, recvId: 200,
            sequence: 3, tokReq: 1,
            userName: "testuser", password: "testpass",
            computerName: "MyMac"
        )
        XCTAssertEqual(packet.readUInt16(at: TokenOffset.code), TokenCode.loginRequest)
    }

    func testLogin_credentials_are_encoded() {
        let packet = PacketBuilder.login(
            innerSeq: 1, sendId: 100, recvId: 200,
            sequence: 3, tokReq: 1,
            userName: "testuser", password: "testpass",
            computerName: "MyMac"
        )
        // Encoded credentials should NOT be plaintext
        let userBytes = packet.subdata(in: LoginOffset.userName..<LoginOffset.userName + 8)
        XCTAssertNotEqual(userBytes, Data("testuser".utf8))
    }

    func testLogin_computerName_is_plaintext() {
        let packet = PacketBuilder.login(
            innerSeq: 1, sendId: 100, recvId: 200,
            sequence: 3, tokReq: 1,
            userName: "testuser", password: "testpass",
            computerName: "MyMac"
        )
        let compBytes = packet.subdata(in: LoginOffset.computer..<LoginOffset.computer + 5)
        XCTAssertEqual(compBytes, Data("MyMac".utf8))
    }

    // MARK: - CIV Packet

    func testCivPacket_wrapsData() {
        let civData = CIV.buildFrame(command: CIV.Command.readFrequency)
        let packet = PacketBuilder.civPacket(
            sequence: 10, sendId: 100, recvId: 200,
            civSequence: 5, civData: civData
        )
        // Total = 21 (header) + civData.count
        XCTAssertEqual(packet.count, 21 + civData.count)
    }

    func testCivPacket_marker() {
        let civData = Data([0xFE, 0xFE, 0xA4, 0xE0, 0x03, 0xFD])
        let packet = PacketBuilder.civPacket(
            sequence: 1, sendId: 100, recvId: 200,
            civSequence: 1, civData: civData
        )
        XCTAssertEqual(packet[CIVPacketOffset.cmd], 0xC1)
    }

    func testCivPacket_civLength() {
        let civData = Data([0xFE, 0xFE, 0xA4, 0xE0, 0x03, 0xFD])
        let packet = PacketBuilder.civPacket(
            sequence: 1, sendId: 100, recvId: 200,
            civSequence: 1, civData: civData
        )
        XCTAssertEqual(packet.readUInt16(at: CIVPacketOffset.length), UInt16(civData.count))
    }

    func testCivPacket_civDataIntact() {
        let civData = Data([0xFE, 0xFE, 0xA4, 0xE0, 0x03, 0xFD])
        let packet = PacketBuilder.civPacket(
            sequence: 1, sendId: 100, recvId: 200,
            civSequence: 1, civData: civData
        )
        let extracted = packet.subdata(in: CIVPacketOffset.data..<CIVPacketOffset.data + civData.count)
        XCTAssertEqual(extracted, civData)
    }

    // MARK: - OpenClose Packet

    func testOpenClose_size() {
        let packet = PacketBuilder.openClose(
            sequence: 1, sendId: 100, recvId: 200,
            civSequence: 1, isOpen: true
        )
        XCTAssertEqual(packet.count, 22)
    }

    func testOpenClose_openRequest() {
        let packet = PacketBuilder.openClose(
            sequence: 1, sendId: 100, recvId: 200,
            civSequence: 1, isOpen: true
        )
        XCTAssertEqual(packet[OpenCloseOffset.cmd], 0xC0)
        XCTAssertEqual(packet[OpenCloseOffset.request], 0x04)
    }

    func testOpenClose_closeRequest() {
        let packet = PacketBuilder.openClose(
            sequence: 1, sendId: 100, recvId: 200,
            civSequence: 1, isOpen: false
        )
        XCTAssertEqual(packet[OpenCloseOffset.request], 0x00)
    }

    // MARK: - CredentialCodec

    func testCredentialCodec_encode_produces16Bytes() {
        let encoded = CredentialCodec.encode("test")
        XCTAssertEqual(encoded.count, 16)
    }

    func testCredentialCodec_encode_zeroPads() {
        let encoded = CredentialCodec.encode("ab")
        // Bytes after position 1 (for "ab") should be zero-padded
        for i in 2..<16 {
            XCTAssertEqual(encoded[i], 0, "Byte \(i) should be zero")
        }
    }

    func testCredentialCodec_encode_notPlaintext() {
        let encoded = CredentialCodec.encode("admin")
        XCTAssertNotEqual(encoded.prefix(5), Data("admin".utf8))
    }

    func testCredentialCodec_encode_deterministic() {
        let first = CredentialCodec.encode("password")
        let second = CredentialCodec.encode("password")
        XCTAssertEqual(first, second)
    }

    func testCredentialCodec_encode_differentInputs_differentOutputs() {
        let a = CredentialCodec.encode("alice")
        let b = CredentialCodec.encode("bob")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Data Extension Helpers

    func testReadWriteUInt16_roundTrip() {
        var data = Data(count: 4)
        data.writeUInt16(0xABCD, at: 0)
        XCTAssertEqual(data.readUInt16(at: 0), 0xABCD)
    }

    func testReadWriteUInt32_roundTrip() {
        var data = Data(count: 8)
        data.writeUInt32(0xDEADBEEF, at: 0)
        XCTAssertEqual(data.readUInt32(at: 0), 0xDEADBEEF)
    }

    func testReadWriteUInt16_littleEndian() {
        var data = Data(count: 2)
        data.writeUInt16(0x0102, at: 0)
        // Little-endian: low byte first
        XCTAssertEqual(data[0], 0x02)
        XCTAssertEqual(data[1], 0x01)
    }

    func testReadWriteUInt32_littleEndian() {
        var data = Data(count: 4)
        data.writeUInt32(0x01020304, at: 0)
        XCTAssertEqual(data[0], 0x04)
        XCTAssertEqual(data[1], 0x03)
        XCTAssertEqual(data[2], 0x02)
        XCTAssertEqual(data[3], 0x01)
    }

    func testReadWriteUInt32BE_bigEndian() {
        var data = Data(count: 4)
        data.writeUInt32BE(0x01020304, at: 0)
        XCTAssertEqual(data[0], 0x01)
        XCTAssertEqual(data[1], 0x02)
        XCTAssertEqual(data[2], 0x03)
        XCTAssertEqual(data[3], 0x04)
        XCTAssertEqual(data.readUInt32BE(at: 0), 0x01020304)
    }

    func testReadUInt16_outOfBounds_returnsZero() {
        let data = Data(count: 1)
        XCTAssertEqual(data.readUInt16(at: 0), 0)
    }

    func testReadUInt32_outOfBounds_returnsZero() {
        let data = Data(count: 2)
        XCTAssertEqual(data.readUInt32(at: 0), 0)
    }

    func testWriteUInt16_outOfBounds_noOp() {
        var data = Data(count: 1)
        data.writeUInt16(0xFFFF, at: 0)
        // Should be a no-op, not crash
        XCTAssertEqual(data[0], 0)
    }
}
