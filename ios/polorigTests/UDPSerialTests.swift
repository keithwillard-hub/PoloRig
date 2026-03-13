import XCTest
@testable import PoloRig

final class UDPSerialTests: XCTestCase {

    private var serial: UDPSerial!

    override func setUp() {
        super.setUp()
        serial = UDPSerial(host: "192.168.1.1", port: 50002)
    }

    override func tearDown() {
        serial = nil
        super.tearDown()
    }

    // MARK: - Init

    func testInit_notWaitingForReply() {
        XCTAssertFalse(serial.isWaitingForReply)
    }

    func testInit_queueEmpty() {
        XCTAssertEqual(serial.queueDepth, 0)
    }

    func testInit_notConnected() {
        XCTAssertFalse(serial.isConnected)
    }

    // MARK: - FlushQueue

    func testFlushQueue_clearsWaitFlag() {
        // Queue a command (connection is nil so send is no-op, but queue state changes)
        serial.sendCIV(data: Data([0xFE, 0xFE, 0xA4, 0xE0, 0x03, 0xFD]))

        let expectation = expectation(description: "flush completes")
        // flushQueue dispatches async on the serial's queue
        serial.flushQueue()
        // Give the queue time to process
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertFalse(self.serial.isWaitingForReply)
            XCTAssertEqual(self.serial.queueDepth, 0)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - CI-V Data Packet Handling

    func testHandleDataPacket_civMarker_callsOnCIVReceived() {
        let expectation = expectation(description: "CI-V received")

        var receivedData: Data?
        serial.onCIVReceived = { data in
            receivedData = data
            expectation.fulfill()
        }

        // Build a packet that looks like a CI-V response from the radio
        // Header: 21 bytes (civHeader), then CI-V data
        let civData = Data([0xFE, 0xFE, 0xE0, 0xA4, 0x03, 0x00, 0x60, 0x05, 0x14, 0x00, 0xFD])
        var packet = Data(count: Int(PacketSize.civHeader))
        // Set total packet length
        packet.writeUInt32(UInt32(PacketSize.civHeader) + UInt32(civData.count), at: ControlOffset.length)
        packet.writeUInt16(PacketType.idle, at: ControlOffset.type)
        packet.writeUInt32(serial.myId, at: ControlOffset.recvId)
        // Set CI-V marker and length in the CIV header portion
        packet[CIVPacketOffset.cmd] = 0xC1
        packet.writeUInt16(UInt16(civData.count), at: CIVPacketOffset.length)
        // Append actual CI-V data
        packet.append(civData)

        serial.handlePacket(packet)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(receivedData, civData)
    }

    func testHandleDataPacket_noCivMarker_doesNotCallOnCIVReceived() {
        var called = false
        serial.onCIVReceived = { _ in
            called = true
        }

        // Build a data packet without the CI-V marker (0xC1)
        var packet = Data(count: Int(PacketSize.civHeader) + 6)
        packet.writeUInt32(UInt32(packet.count), at: ControlOffset.length)
        packet.writeUInt16(PacketType.idle, at: ControlOffset.type)
        packet[CIVPacketOffset.cmd] = 0x00 // Not CI-V

        serial.handlePacket(packet)

        // Give a moment for any async processing
        let expectation = expectation(description: "wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
        XCTAssertFalse(called)
    }

    func testHandleDataPacket_tooSmallForCIV_doesNotCrash() {
        // Packet exactly at civHeader size with no CI-V data
        var packet = Data(count: Int(PacketSize.civHeader))
        packet.writeUInt32(PacketSize.civHeader, at: ControlOffset.length)
        packet.writeUInt16(PacketType.idle, at: ControlOffset.type)

        // Should not crash — falls through to super.handleDataPacket
        serial.handlePacket(packet)
    }

    // MARK: - OnDisconnected Cleanup

    func testOnDisconnected_clearsState() {
        // Simulate a disconnect packet
        var packet = Data(count: 16)
        packet.writeUInt32(PacketSize.control, at: ControlOffset.length)
        packet.writeUInt16(PacketType.disconnect, at: ControlOffset.type)

        serial.handlePacket(packet)

        let expectation = expectation(description: "state cleared")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.serial.queueDepth, 0)
            XCTAssertFalse(self.serial.isWaitingForReply)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - CI-V ACK/NAK Handling

    func testHandleCIVResponse_ack_clearsWaitFlag() {
        let expectation = expectation(description: "ack processed")

        // Queue a command to set waitingForReply
        serial.sendCIV(data: Data([0xFE, 0xFE, 0xA4, 0xE0, 0x03, 0xFD])) { success in
            XCTAssertTrue(success)
            expectation.fulfill()
        }

        // Give queue time to process the send
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Build an ACK response from the radio
            let ackCIV = Data([0xFE, 0xFE, 0xE0, 0xA4, 0xFB, 0xFD])
            var packet = Data(count: Int(PacketSize.civHeader))
            packet.writeUInt32(UInt32(PacketSize.civHeader) + UInt32(ackCIV.count), at: ControlOffset.length)
            packet.writeUInt16(PacketType.idle, at: ControlOffset.type)
            packet[CIVPacketOffset.cmd] = 0xC1
            packet.writeUInt16(UInt16(ackCIV.count), at: CIVPacketOffset.length)
            packet.append(ackCIV)

            self.serial.handlePacket(packet)
        }

        wait(for: [expectation], timeout: 2.0)
        XCTAssertFalse(serial.isWaitingForReply)
    }

    func testHandleCIVResponse_nak_callsCompletionWithFalse() {
        let expectation = expectation(description: "nak processed")

        serial.sendCIV(data: Data([0xFE, 0xFE, 0xA4, 0xE0, 0x03, 0xFD])) { success in
            XCTAssertFalse(success)
            expectation.fulfill()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Build a NAK response
            let nakCIV = Data([0xFE, 0xFE, 0xE0, 0xA4, 0xFA, 0xFD])
            var packet = Data(count: Int(PacketSize.civHeader))
            packet.writeUInt32(UInt32(PacketSize.civHeader) + UInt32(nakCIV.count), at: ControlOffset.length)
            packet.writeUInt16(PacketType.idle, at: ControlOffset.type)
            packet[CIVPacketOffset.cmd] = 0xC1
            packet.writeUInt16(UInt16(nakCIV.count), at: CIVPacketOffset.length)
            packet.append(nakCIV)

            self.serial.handlePacket(packet)
        }

        wait(for: [expectation], timeout: 2.0)
        XCTAssertFalse(serial.isWaitingForReply)
    }

    // MARK: - Unsolicited CI-V Data

    func testHandleCIVResponse_unsolicitedData_passedToHandler() {
        let expectation = expectation(description: "unsolicited data")

        var receivedData: Data?
        serial.onCIVReceived = { data in
            receivedData = data
            expectation.fulfill()
        }

        // Unsolicited frequency update from radio (broadcast, not addressed to controller)
        // dst=0x00 (broadcast), src=0xA4 (radio), cmd=0x00 (transceive freq)
        let freqCIV = Data([0xFE, 0xFE, 0x00, 0xA4, 0x00, 0x00, 0x60, 0x05, 0x14, 0x00, 0xFD])
        var packet = Data(count: Int(PacketSize.civHeader))
        packet.writeUInt32(UInt32(PacketSize.civHeader) + UInt32(freqCIV.count), at: ControlOffset.length)
        packet.writeUInt16(PacketType.idle, at: ControlOffset.type)
        packet[CIVPacketOffset.cmd] = 0xC1
        packet.writeUInt16(UInt16(freqCIV.count), at: CIVPacketOffset.length)
        packet.append(freqCIV)

        serial.handlePacket(packet)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(receivedData, freqCIV)
    }
}
