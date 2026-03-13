import XCTest
@testable import PoloRig

/// Test subclass that captures hook calls without requiring NWConnection.
private class TestableUDPBase: UDPBase {
    var readyCalled = false
    var disconnectedCalled = false

    override func onReady() {
        readyCalled = true
    }

    override func onDisconnected() {
        disconnectedCalled = true
    }
}

final class UDPBaseTests: XCTestCase {

    private var udp: TestableUDPBase!

    override func setUp() {
        super.setUp()
        udp = TestableUDPBase(host: "192.168.1.1", port: 50001)
    }

    override func tearDown() {
        udp = nil
        super.tearDown()
    }

    // MARK: - Init

    func testInit_isConnectedFalse() {
        XCTAssertFalse(udp.isConnected)
    }

    func testInit_remoteIdZero() {
        XCTAssertEqual(udp.remoteId, 0)
    }

    func testInit_sequenceZero() {
        XCTAssertEqual(udp.sequence, 0)
    }

    func testInit_myIdNonZero() {
        XCTAssertNotEqual(udp.myId, 0)
    }

    // MARK: - Sequence

    func testNextSequence_increments() {
        let s1 = udp.nextSequence()
        let s2 = udp.nextSequence()
        XCTAssertEqual(s1, 1)
        XCTAssertEqual(s2, 2)
    }

    func testNextSequence_wrapsAtMax() {
        // Set sequence near max via repeated calls, then verify wrap
        // Use reflection to set sequence directly
        for _ in 0..<0xFFFF {
            _ = udp.nextSequence()
        }
        XCTAssertEqual(udp.sequence, 0xFFFF)
        let wrapped = udp.nextSequence()
        XCTAssertEqual(wrapped, 0) // &+= wraps
    }

    // MARK: - IAmHere Handling

    func testHandleIAmHere_setsRemoteId() {
        var packet = Data(count: 16)
        packet.writeUInt32(PacketSize.control, at: ControlOffset.length)
        packet.writeUInt16(PacketType.iAmHere, at: ControlOffset.type)
        packet.writeUInt32(0xAABBCCDD, at: ControlOffset.sendId)

        udp.handlePacket(packet)

        XCTAssertEqual(udp.remoteId, 0xAABBCCDD)
    }

    // MARK: - IAmReady Handling

    func testHandleIAmReady_callsOnReady() {
        var packet = Data(count: 16)
        packet.writeUInt32(PacketSize.control, at: ControlOffset.length)
        packet.writeUInt16(PacketType.areYouReady, at: ControlOffset.type)

        udp.handlePacket(packet)

        XCTAssertTrue(udp.readyCalled)
    }

    // MARK: - Disconnect Handling

    func testHandleDisconnect_setsNotConnected() {
        udp.isConnected = true

        var packet = Data(count: 16)
        packet.writeUInt32(PacketSize.control, at: ControlOffset.length)
        packet.writeUInt16(PacketType.disconnect, at: ControlOffset.type)

        udp.handlePacket(packet)

        XCTAssertFalse(udp.isConnected)
    }

    func testHandleDisconnect_callsOnDisconnected() {
        var packet = Data(count: 16)
        packet.writeUInt32(PacketSize.control, at: ControlOffset.length)
        packet.writeUInt16(PacketType.disconnect, at: ControlOffset.type)

        udp.handlePacket(packet)

        XCTAssertTrue(udp.disconnectedCalled)
    }

    // MARK: - Packet Routing

    func testHandlePacket_tooSmall_ignored() {
        let tiny = Data(count: 4)
        // Should not crash
        udp.handlePacket(tiny)
        XCTAssertFalse(udp.readyCalled)
        XCTAssertFalse(udp.disconnectedCalled)
    }

    func testHandlePacket_unknownType_noSideEffects() {
        var packet = Data(count: 16)
        packet.writeUInt32(PacketSize.control, at: ControlOffset.length)
        packet.writeUInt16(0xFFFF, at: ControlOffset.type)

        udp.handlePacket(packet)

        XCTAssertFalse(udp.readyCalled)
        XCTAssertFalse(udp.disconnectedCalled)
        XCTAssertEqual(udp.remoteId, 0)
    }

    func testHandlePacket_pingType_noReadyOrDisconnect() {
        // Create a ping-sized packet with ping type
        var packet = Data(count: Int(PacketSize.ping))
        packet.writeUInt32(PacketSize.ping, at: ControlOffset.length)
        packet.writeUInt16(PacketType.ping, at: ControlOffset.type)
        // Mark as request (0x00) with wrong recvId so it won't match
        packet[PingOffset.request] = 0x00
        packet.writeUInt32(0, at: ControlOffset.recvId)

        udp.handlePacket(packet)

        XCTAssertFalse(udp.readyCalled)
        XCTAssertFalse(udp.disconnectedCalled)
    }

    // MARK: - Handshake State Machine

    func testHandshakeFlow_iAmHere_thenAreYouReady() {
        // Simulate: radio sends IAmHere (sets remoteId)
        var iAmHere = Data(count: 16)
        iAmHere.writeUInt32(PacketSize.control, at: ControlOffset.length)
        iAmHere.writeUInt16(PacketType.iAmHere, at: ControlOffset.type)
        iAmHere.writeUInt32(0x12345678, at: ControlOffset.sendId)
        udp.handlePacket(iAmHere)

        XCTAssertEqual(udp.remoteId, 0x12345678)
        XCTAssertFalse(udp.readyCalled)

        // Simulate: radio sends AreYouReady (triggers onReady)
        var areYouReady = Data(count: 16)
        areYouReady.writeUInt32(PacketSize.control, at: ControlOffset.length)
        areYouReady.writeUInt16(PacketType.areYouReady, at: ControlOffset.type)
        udp.handlePacket(areYouReady)

        XCTAssertTrue(udp.readyCalled)
    }

    // MARK: - SendTracked

    func testSendTracked_doesNotCrashWithNilConnection() {
        var packet = Data(count: 16)
        packet.writeUInt32(PacketSize.control, at: ControlOffset.length)
        packet.writeUInt16(0, at: ControlOffset.type)
        packet.writeUInt16(42, at: ControlOffset.sequence)

        // Should not crash — connection is nil, send is a no-op
        udp.sendTracked(packet)
    }

    // MARK: - Timer Cleanup

    func testStopTimers_doesNotCrash() {
        udp.stopTimers()
    }

    func testCancelResendTimer_doesNotCrash() {
        udp.cancelResendTimer()
    }

    // MARK: - Latency

    func testLatency_defaultsToZero() {
        XCTAssertEqual(udp.latencyMs, 0)
    }
}
