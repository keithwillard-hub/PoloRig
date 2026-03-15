import Foundation
import os

private let logger = Logger(subsystem: "com.ic705.session", category: "UDPSerial")

/// Manages the serial port (50002) connection.
/// Wraps CI-V commands in the RS-BA1 UDP packet format and manages the CI-V send queue.
public final class UDPSerial: UDPBase {

    private var civSequence: UInt16 = 0
    private var waitingForReply = false
    private var keepaliveSuspendedForCIV = false
    private var closeAcknowledged = false

    /// Queue of CI-V commands waiting to be sent.
    private var commandQueue: [(data: Data, expectsReply: Bool, completion: ((Bool) -> Void)?)] = []

    /// Called when a CI-V response is received from the radio.
    public var onCIVReceived: ((Data) -> Void)?

    /// Called when the serial port handshake completes and CI-V commands can be sent.
    public var onSerialReady: (() -> Void)?

    /// Number of commands waiting in the queue (for diagnostics)
    public var queueDepth: Int { commandQueue.count }

    /// Whether the serial port is waiting for a CI-V response
    public var isWaitingForReply: Bool { waitingForReply }

    /// Flush all pending commands from the queue and reset the wait flag.
    /// Use before time-critical commands (e.g., CW) to bypass stale polling requests.
    public func flushQueue() {
        queue.sync { [weak self] in
            guard let self else { return }
            self.commandQueue.removeAll()
            self.waitingForReply = false
            self.pendingCompletion = nil
            self.resumeBackgroundTrafficIfNeeded()
            logger.debug("flushQueue: Queue flushed, state reset")
        }
    }

    public func resumeDeferredBackgroundTraffic() {
        queue.async { [weak self] in
            self?.resumeBackgroundTrafficIfNeeded()
        }
    }

    // MARK: - Init

    public override init(host: String, port: UInt16, localPort: UInt16 = 0) {
        super.init(host: host, port: port, localPort: localPort)
    }

    // MARK: - Handshake

    override func onReady() {
        logger.info("Serial port ready, sending OpenClose")
        NSLog("[UDPSerial] onReady called, sending OpenClose(isOpen: true)")
        onStage?("Serial socket ready; sending OpenClose")
        sendOpenClose(isOpen: true)
        isConnected = true
        DispatchQueue.main.async { [weak self] in
            NSLog("[UDPSerial] Calling onSerialReady callback")
            self?.onSerialReady?()
        }
    }

    // MARK: - Open/Close

    private func sendOpenClose(isOpen: Bool) {
        civSequence &+= 1
        if !isOpen {
            closeAcknowledged = false
        }
        let packet = PacketBuilder.openClose(
            sequence: nextSequence(),
            sendId: myId,
            recvId: remoteId,
            civSequence: civSequence,
            isOpen: isOpen
        )
        let packetHex = packet.map { String(format: "%02X", $0) }.joined(separator: " ")
        NSLog("[UDPSerial] sendOpenClose(isOpen: %d): [%@]", isOpen, packetHex)
        DebugTrace.write("UDPSerial", "sendOpenClose isOpen=\(isOpen) packet=[\(packetHex)]")
        send(packet)
    }

    // MARK: - Send CI-V

    /// Queue a CI-V frame for transmission. The completion handler is called
    /// with `true` on ACK, `false` on NAK or timeout.
    public func sendCIV(data: Data, expectsReply: Bool = true, completion: ((Bool) -> Void)? = nil) {
        let hexString = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        logger.debug("sendCIV: Queuing CI-V frame: [\(hexString)]")
        NSLog("[UDPSerial] sendCIV: Queuing CI-V frame: [%@]", hexString)
        DebugTrace.write("UDPSerial", "queue sendCIV expectsReply=\(expectsReply) payload=[\(hexString)]")

        queue.async { [weak self] in
            guard let self else { return }
            self.commandQueue.append((data: data, expectsReply: expectsReply, completion: completion))
            logger.debug("sendCIV: Queue depth now: \(self.commandQueue.count)")
            NSLog("[UDPSerial] Queue depth: %d", self.commandQueue.count)
            self.processQueue()
        }
    }

    private func processQueue() {
        NSLog("[UDPSerial] processQueue: waitingForReply=%d, queue.count=%d", waitingForReply, commandQueue.count)
        guard !waitingForReply, !commandQueue.isEmpty else {
            if waitingForReply {
                logger.debug("processQueue: Waiting for reply, not processing")
            }
            if commandQueue.isEmpty {
                logger.debug("processQueue: Queue empty, nothing to process")
            }
            return
        }

        let entry = commandQueue.removeFirst()
        civSequence &+= 1
        suspendBackgroundTrafficIfNeeded(for: entry.data)

        let packet = PacketBuilder.civPacket(
            sequence: nextSequence(),
            sendId: myId,
            recvId: remoteId,
            civSequence: civSequence,
            civData: entry.data
        )
        let packetHex = packet.map { String(format: "%02X", $0) }.joined(separator: " ")
        let civDataHex = entry.data.map { String(format: "%02X", $0) }.joined(separator: " ")
        logger.debug("processQueue: Sending packet (civSeq=\(self.civSequence)): UDP packet [\(packetHex)]")
        logger.debug("processQueue: CI-V payload: [\(civDataHex)]")
        DebugTrace.write("UDPSerial", "processQueue civSeq=\(self.civSequence) expectsReply=\(entry.expectsReply) payload=[\(civDataHex)]")
        send(packet)

        guard entry.expectsReply else {
            logger.debug("processQueue: civSeq=\(self.civSequence) is fire-and-forget")
            DebugTrace.write("UDPSerial", "processQueue civSeq=\(self.civSequence) fire-and-forget")
            DispatchQueue.main.async {
                entry.completion?(true)
            }
            processQueue()
            return
        }

        waitingForReply = true

        // Timeout: if no response in 3 seconds, mark as failed and move on
        let timeoutSeq = civSequence
        queue.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, self.waitingForReply, self.civSequence == timeoutSeq else { return }
            logger.warning("CI-V command timeout (civSeq=\(timeoutSeq))")
            NSLog("[UDPSerial] TIMEOUT for civSeq=%d", timeoutSeq)
            DebugTrace.write("UDPSerial", "timeout civSeq=\(timeoutSeq)")
            self.waitingForReply = false
            self.resumeBackgroundTrafficIfNeeded()
            DispatchQueue.main.async {
                entry.completion?(false)
            }
            self.processQueue()
        }

        // Store the completion for when we get a response
        logger.debug("processQueue: Storing pendingCompletion for civSeq=\(timeoutSeq)")
        pendingCompletion = entry.completion
        logger.debug("processQueue: Done, waiting for response...")
    }

    private var pendingCompletion: ((Bool) -> Void)?

    // MARK: - Receive CI-V

    override func handleDataPacket(_ data: Data) {
        NSLog("[UDPSerial:%@] handleDataPacket called with %d bytes", socketLabel, data.count)
        guard data.count > Int(PacketSize.civHeader) else {
            NSLog("[UDPSerial:%@] Packet too short (%d bytes), ignoring non-CI-V serial packet",
                  socketLabel, data.count)
            return
        }

        // Check for CI-V marker
        let marker = data[CIVPacketOffset.cmd]
        NSLog("[UDPSerial:%@] CI-V marker at 0x10: 0x%02X (expected 0xC1)", socketLabel, marker)
        guard marker == 0xC1 else {
            NSLog("[UDPSerial:%@] Not a CI-V packet, ignoring on serial channel", socketLabel)
            return
        }

        // Extract CI-V data
        let civLength = Int(data.readUInt16(at: CIVPacketOffset.length))
        let civStart = CIVPacketOffset.data
        NSLog("[UDPSerial:%@] CI-V length: %d, start: %d, data.count: %d",
              socketLabel, civLength, civStart, data.count)
        guard civStart + civLength <= data.count else {
            NSLog("[UDPSerial:%@] CI-V data exceeds packet size", socketLabel)
            return
        }

        let civData = data.subdata(in: civStart..<civStart + civLength)
        let civHex = civData.map { String(format: "%02X", $0) }.joined(separator: " ")
        NSLog("[UDPSerial:%@] CI-V payload received: [%@]", socketLabel, civHex)
        DebugTrace.write("UDPSerial", "received CI-V payload=[\(civHex)]")
        onStage?("CI-V payload received (\(civData.count) bytes)")
        handleCIVResponse(civData)
    }

    override func handlePacket(_ data: Data) {
        guard data.count >= Int(PacketSize.control) else {
            DebugTrace.write("UDPSerial", "handlePacket short=\(data.count)")
            return
        }

        let type = data.readUInt16(at: ControlOffset.type)
        let seq = data.readUInt16(at: ControlOffset.sequence)
        let marker = data.count > 0x10 ? String(format: "%02X", data[0x10]) : "--"
        DebugTrace.write("UDPSerial", "handlePacket type=0x\(String(format: "%04X", type)) seq=\(seq) marker=0x\(marker) bytes=\(data.count)")

        switch type {
        case PacketType.iAmHere:
            handleIAmHere(data)

        case PacketType.areYouReady:
            handleIAmReady(data)

        case PacketType.ping:
            handleSerialPing(data)

        case PacketType.disconnect:
            logger.info("Received serial disconnect")
            handleDisconnect()

        case PacketType.idle:
            handleSerialIdle(data)

        default:
            logger.debug("Ignoring serial packet type=0x\(String(format: "%04X", type))")
        }
    }

    private func handleCIVResponse(_ civData: Data) {
        let civHex = civData.map { String(format: "%02X", $0) }.joined(separator: " ")
        logger.debug("handleCIVResponse: Raw CI-V data: [\(civHex)]")

        guard civData.count >= 6 else {  // Minimum: FE FE dst src cmd FD
            logger.warning("handleCIVResponse: CI-V data too short (\(civData.count) bytes)")
            return
        }

        // Check for valid CI-V frame
        guard civData[0] == 0xFE, civData[1] == 0xFE else {
            logger.warning("handleCIVResponse: Invalid CI-V preamble, expected FE FE")
            return
        }
        guard civData[civData.count - 1] == 0xFD else {
            logger.warning("handleCIVResponse: Invalid CI-V terminator, expected FD")
            return
        }

        let destination = civData[2]
        let source = civData[3]
        let command = civData[4]

        logger.debug("handleCIVResponse: dst=0x\(String(destination, radix: 16)) src=0x\(String(source, radix: 16)) cmd=0x\(String(command, radix: 16))")

        if command == CIV.ack {
            logger.debug("CI-V ACK received dst=0x\(String(destination, radix: 16)) src=0x\(String(source, radix: 16))")
            NSLog("[UDPSerial] ACK received! dst=0x%02x src=0x%02x", destination, source)
            let completion = self.pendingCompletion
            NSLog("[UDPSerial] pendingCompletion is %@", completion != nil ? "set" : "nil")
            self.pendingCompletion = nil
            self.waitingForReply = false
            self.resumeBackgroundTrafficIfNeeded()
            DispatchQueue.main.async {
                logger.debug("handleCIVResponse: Calling completion(true) on main queue")
                NSLog("[UDPSerial] Calling completion(true)")
                completion?(true)
            }
            processQueue()
            return
        }

        if command == CIV.nak {
            logger.warning("CI-V NAK received dst=0x\(String(destination, radix: 16)) src=0x\(String(source, radix: 16))")
            NSLog("[UDPSerial] NAK received! dst=0x%02x src=0x%02x", destination, source)
            let completion = self.pendingCompletion
            NSLog("[UDPSerial] pendingCompletion is %@", completion != nil ? "set" : "nil")
            self.pendingCompletion = nil
            self.waitingForReply = false
            self.resumeBackgroundTrafficIfNeeded()
            DispatchQueue.main.async {
                logger.debug("handleCIVResponse: Calling completion(false) on main queue")
                NSLog("[UDPSerial] Calling completion(false)")
                completion?(false)
            }
            processQueue()
            return
        }

        // Check if this is addressed to us (or broadcast)
        let isForUs = destination == CIV.controllerAddress || destination == 0x00
        logger.debug("handleCIVResponse: isForUs=\(isForUs) (destination=0x\(String(destination, radix: 16)), ourAddr=0x\(String(CIV.controllerAddress, radix: 16)))")

        // Pass unsolicited data to handler
        onCIVReceived?(civData)

        // If we got a data response (not ACK/NAK), still clear the wait flag
        if isForUs && self.waitingForReply {
            logger.debug("handleCIVResponse: Data response for us, calling completion(true)")
            let completion = self.pendingCompletion
            self.pendingCompletion = nil
            self.waitingForReply = false
            self.resumeBackgroundTrafficIfNeeded()
            DispatchQueue.main.async {
                completion?(true)
            }
            processQueue()
        } else if self.waitingForReply {
            logger.debug("handleCIVResponse: Not for us or not waiting - isForUs=\(isForUs), waitingForReply=\(self.waitingForReply)")
        }
    }

    // MARK: - Disconnect

    public override func disconnect() {
        sendOpenClose(isOpen: false)
        super.disconnect()
    }

    public var hasCloseAcknowledged: Bool {
        closeAcknowledged
    }

    public func requestClose() {
        queue.async { [weak self] in
            self?.sendOpenClose(isOpen: false)
        }
    }

    override func onDisconnected() {
        commandQueue.removeAll()
        waitingForReply = false
        pendingCompletion = nil
        keepaliveSuspendedForCIV = false
        closeAcknowledged = false
    }

    private func suspendBackgroundTrafficIfNeeded(for civData: Data) {
        guard isCWCommand(civData), !keepaliveSuspendedForCIV else { return }
        keepaliveSuspendedForCIV = true
        logger.debug("Suspending serial background traffic for CW command")
        suspendBackgroundTraffic()
    }

    private func resumeBackgroundTrafficIfNeeded() {
        guard keepaliveSuspendedForCIV else { return }
        keepaliveSuspendedForCIV = false
        logger.debug("Resuming serial background traffic after CW command")
        resumeBackgroundTraffic()
    }

    private func isCWCommand(_ civData: Data) -> Bool {
        civData.count >= 6 && civData[4] == CIV.Command.sendCW
    }

    private func handleSerialPing(_ data: Data) {
        guard data.count >= Int(PacketSize.ping) else { return }
        let isRequest = data[PingOffset.request] == 0x00
        DebugTrace.write("UDPSerial", "handleSerialPing isRequest=\(isRequest)")
        guard isRequest else { return }

        let reply = PacketBuilder.pongReply(from: data, sendId: myId, recvId: remoteId)
        send(reply)
    }

    private func handleSerialIdle(_ data: Data) {
        guard data.count > 0x10 else { return }
        let marker = data[0x10]
        switch marker {
        case 0xC1:
            handleDataPacket(data)
        case 0xC0:
            closeAcknowledged = true
            DebugTrace.write("UDPSerial", "handleSerialIdle openCloseAck bytes=\(data.count)")
        default:
            DebugTrace.write("UDPSerial", "handleSerialIdle ignored marker=0x\(String(format: "%02X", marker)) bytes=\(data.count)")
        }
    }
}
