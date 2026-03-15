import XCTest
@testable import Transport

final class DisconnectPacketTests: XCTestCase {
    func testTokenRemovePacketUsesRemoveResponseCode() {
        let packet = PacketBuilder.tokenRemove(
            innerSeq: 7,
            sendId: 0x01020304,
            recvId: 0x05060708,
            sequence: 9,
            tokReq: 0x0A0B,
            token: 0x0C0D0E0F
        )

        XCTAssertEqual(packet.readUInt16(at: ControlOffset.type), PacketType.idle)
        XCTAssertEqual(packet.readUInt16(at: TokenOffset.code), TokenCode.tokenAck)
        XCTAssertEqual(packet.readUInt16(at: TokenOffset.res), TokenRes.remove)
        XCTAssertEqual(packet[TokenOffset.innerSeq], 7)
        XCTAssertEqual(packet.readUInt16(at: TokenOffset.tokReq), 0x0A0B)
        XCTAssertEqual(packet.readUInt32(at: TokenOffset.token), 0x0C0D0E0F)
    }

    func testOpenClosePacketUsesCloseRequestByte() {
        let packet = PacketBuilder.openClose(
            sequence: 3,
            sendId: 0x11111111,
            recvId: 0x22222222,
            civSequence: 4,
            isOpen: false
        )

        XCTAssertEqual(packet.readUInt16(at: ControlOffset.type), PacketType.idle)
        XCTAssertEqual(packet[OpenCloseOffset.cmd], 0xC0)
        XCTAssertEqual(packet.readUInt16(at: OpenCloseOffset.length), 0x0001)
        XCTAssertEqual(packet.readUInt16(at: OpenCloseOffset.sequence), 4)
        XCTAssertEqual(packet[OpenCloseOffset.request], 0x00)
    }
}
