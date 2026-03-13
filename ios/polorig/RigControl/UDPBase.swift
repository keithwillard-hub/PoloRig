import Foundation
import Network
import os

private let logger = Logger(subsystem: "com.ic705cwlogger", category: "UDPBase")

/// Base class for UDP connections to the IC-705.
/// Handles connection lifecycle, ping/pong keepalive, idle packets, and retransmit.
public class UDPBase {
    let host: NWEndpoint.Host
    let port: NWEndpoint.Port
    let preferredLocalPort: UInt16
    private(set) var connection: NWConnection?

    let myId: UInt32 = UInt32.random(in: 1...UInt32.max)
    private(set) var remoteId: UInt32 = 0

    private(set) var sequence: UInt16 = 0      // data/idle packets (type 0x00)
    private var pingSequence: UInt16 = 0

    private var pingTimer: DispatchSourceTimer?
    private var idleTimer: DispatchSourceTimer?
    private var resendTimer: DispatchSourceTimer?
    private var connectTimer: DispatchSourceTimer?

    /// Overall connection timeout in seconds. If the handshake doesn't
    /// complete within this window, the connection is torn down.
    public var connectTimeout: TimeInterval = 10.0

    private var retryPacket: Data?
    private var sentPackets: [(seq: UInt16, data: Data)] = []
    private let maxRetransmitBuffer = 20

    private var pingDataB: UInt16 = UInt16.random(in: 0...UInt16.max)
    private var lastPingSent: Date?
    public var latencyMs: Double = 0

    public var isConnected = false
    private var disconnecting = false
    public var onStage: ((String) -> Void)?

    let queue = DispatchQueue(label: "com.ic705cwlogger.udp", qos: .userInitiated)

    public init(host: String, port: UInt16, localPort: UInt16 = 0) {
        // Trim whitespace — JS may pass padded strings
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        // Explicitly parse as IPv4 to avoid DNS resolution on iOS simulator
        if let ipv4 = IPv4Address(host) {
            self.host = .ipv4(ipv4)
        } else if let ipv6 = IPv6Address(host) {
            self.host = .ipv6(ipv6)
        } else {
            self.host = NWEndpoint.Host(host)
        }
        self.port = NWEndpoint.Port(rawValue: port)!
        self.preferredLocalPort = localPort
    }

    // MARK: - Connection Lifecycle

    public func connect() {
        let params = NWParameters.udp
        if preferredLocalPort != 0 {
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.any), port: NWEndpoint.Port(rawValue: preferredLocalPort)!)
        }
        connection = NWConnection(host: host, port: port, using: params)

        connection?.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onStage?("UDP ready on port \(self.port.rawValue)")
                self.startReceiving()
                self.beginHandshake()
            case .waiting(let error):
                logger.debug("Connection waiting: \(error.localizedDescription)")
                self.onStage?("UDP waiting on port \(self.port.rawValue): \(error.localizedDescription)")
            case .failed(let error):
                logger.error("Connection failed: \(error.localizedDescription)")
                self.onStage?("UDP failed on port \(self.port.rawValue): \(error.localizedDescription)")
                self.handleDisconnect()
            case .cancelled:
                logger.debug("Connection cancelled")
            default:
                break
            }
        }

        connection?.start(queue: queue)
        armConnectTimer()
    }

    private func armConnectTimer() {
        connectTimer?.cancel()
        connectTimer = DispatchSource.makeTimerSource(queue: queue)
        connectTimer?.schedule(deadline: .now() + connectTimeout)
        connectTimer?.setEventHandler { [weak self] in
            guard let self, !self.isConnected else { return }
            logger.warning("Connection timeout after \(self.connectTimeout)s")
            self.handleDisconnect()
        }
        connectTimer?.resume()
    }

    public func disconnect() {
        disconnecting = true
        // Disconnect is a control packet — use seq=0 (not tracked)
        let packet = PacketBuilder.disconnect(
            sequence: 0,
            sendId: myId,
            recvId: remoteId
        )
        send(packet)
        // Send twice for reliability
        send(packet)

        armIdleTimer()
    }

    func handleDisconnect() {
        isConnected = false
        disconnecting = false
        connectTimer?.cancel()
        connectTimer = nil
        stopTimers()
        connection?.cancel()
        connection = nil
        onDisconnected()
    }

    // MARK: - Handshake (overridden by subclasses)

    func beginHandshake() {
        // Send AreYouThere (hardcoded seq=0, control packet — not tracked)
        onStage?("Sending AreYouThere on port \(port.rawValue)")
        let ayt = PacketBuilder.areYouThere(sendId: myId)
        send(ayt)
        retryPacket = ayt
        armResendTimer()
    }

    // MARK: - Receiving

    private func startReceiving() {
        connection?.receiveMessage { [weak self] content, _, isComplete, error in
            guard let self else { return }
            if let data = content, !data.isEmpty {
                NSLog("[UDPBase] Received %d bytes", data.count)
                self.handlePacket(data)
            } else {
                NSLog("[UDPBase] No data received (isComplete=%d, error=%@)", isComplete, error?.localizedDescription ?? "nil")
            }
            if error == nil {
                self.startReceiving()
            }
        }
    }

    func handlePacket(_ data: Data) {
        guard data.count >= Int(PacketSize.control) else {
            NSLog("[UDPBase] Packet too short: %d bytes", data.count)
            return
        }

        let type = data.readUInt16(at: ControlOffset.type)
        let hexType = String(format: "0x%04X", type)
        NSLog("[UDPBase] Received packet type: %@", hexType)

        switch type {
        case PacketType.iAmHere:
            handleIAmHere(data)

        case PacketType.areYouReady:
            // Treat as iAmReady for our purposes
            handleIAmReady(data)

        case PacketType.ping:
            handlePing(data)

        case PacketType.retransmit:
            handleRetransmit(data)

        case PacketType.disconnect:
            logger.info("Received disconnect")
            handleDisconnect()

        case PacketType.idle:
            // Could be a token packet, conninfo, CIV, etc. — check length
            handleDataPacket(data)

        default:
            logger.debug("Unknown packet type: \(type)")
        }
    }

    func handleIAmHere(_ data: Data) {
        remoteId = data.readUInt32(at: ControlOffset.sendId)
        logger.info("Got IAmHere, remoteId=\(self.remoteId)")
        NSLog("[UDPBase] Got IAmHere, remoteId=%u", remoteId)
        onStage?("Received IAmHere on port \(port.rawValue)")

        cancelResendTimer()

        // Send AreYouReady (hardcoded seq=1, control packet — not tracked)
        let packet = PacketBuilder.areYouReady(
            sequence: 1,
            sendId: myId,
            recvId: remoteId
        )
        onStage?("Sending AreYouReady on port \(port.rawValue)")
        send(packet)
        retryPacket = packet
        armResendTimer()
    }

    func handleIAmReady(_ data: Data) {
        cancelResendTimer()
        connectTimer?.cancel()
        connectTimer = nil
        onStage?("Received AreYouReady on port \(port.rawValue)")
        NSLog("[UDPBase] Handshake complete, calling onReady()")
        onReady()
    }

    /// Subclasses override to handle data packets (type=0x0000 with >16 bytes)
    func handleDataPacket(_ data: Data) {
        // Base implementation: just reset idle timer
        armIdleTimer()
    }

    // MARK: - Ping/Pong

    private func handlePing(_ data: Data) {
        guard data.count >= Int(PacketSize.ping) else { return }

        let isRequest = data[PingOffset.request] == 0x00
        let senderRecvId = data.readUInt32(at: ControlOffset.recvId)

        if isRequest {
            // Radio is pinging us — reply
            if senderRecvId == myId {
                let reply = PacketBuilder.pongReply(from: data, sendId: myId, recvId: remoteId)
                send(reply)
            } else {
                // Stale session — send disconnect to that ID
                logger.warning("Stale ping from different session")
            }
        } else {
            // This is a pong reply to our ping
            if let sentTime = lastPingSent {
                latencyMs = Date().timeIntervalSince(sentTime) * 500.0
            }
        }
    }

    func startPingTimer() {
        pingTimer?.cancel()
        pingTimer = DispatchSource.makeTimerSource(queue: queue)
        pingTimer?.schedule(deadline: .now() + Timing.pingInterval, repeating: Timing.pingInterval)
        pingTimer?.setEventHandler { [weak self] in
            self?.sendPing()
        }
        pingTimer?.resume()
    }

    private func sendPing() {
        let dataA = UInt16.random(in: 0...UInt16.max)
        pingSequence &+= 1
        let packet = PacketBuilder.ping(
            sequence: pingSequence,
            sendId: myId,
            recvId: remoteId,
            isReply: false,
            dataA: dataA,
            dataB: pingDataB
        )
        lastPingSent = Date()
        send(packet)
    }

    // MARK: - Idle

    func armIdleTimer() {
        idleTimer?.cancel()
        idleTimer = DispatchSource.makeTimerSource(queue: queue)
        idleTimer?.schedule(deadline: .now() + Timing.idleInterval)
        idleTimer?.setEventHandler { [weak self] in
            guard let self else { return }
            if self.disconnecting {
                self.handleDisconnect()
            } else {
                self.sendIdle()
            }
        }
        idleTimer?.resume()
    }

    private func sendIdle() {
        let packet = PacketBuilder.idle(
            sequence: nextSequence(),
            sendId: myId,
            recvId: remoteId
        )
        send(packet)
    }

    // MARK: - Resend

    func armResendTimer() {
        resendTimer?.cancel()
        resendTimer = DispatchSource.makeTimerSource(queue: queue)
        resendTimer?.schedule(deadline: .now() + Timing.resendInterval)
        resendTimer?.setEventHandler { [weak self] in
            guard let self, let packet = self.retryPacket else { return }
            logger.debug("Resending packet")
            self.send(packet)
            self.armResendTimer()
        }
        resendTimer?.resume()
    }

    func cancelResendTimer() {
        resendTimer?.cancel()
        resendTimer = nil
        retryPacket = nil
    }

    // MARK: - Retransmit Handling

    private func handleRetransmit(_ data: Data) {
        guard data.count >= 18 else { return }
        let requestedSeq = data.readUInt16(at: 0x10)
        logger.debug("Retransmit request for seq \(requestedSeq)")

        if let found = sentPackets.first(where: { $0.seq == requestedSeq }) {
            send(found.data)
        } else {
            // Send idle with the requested sequence
            let idle = PacketBuilder.idle(
                sequence: requestedSeq,
                sendId: myId,
                recvId: remoteId
            )
            send(idle)
        }
    }

    // MARK: - Send

    func send(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { error in
            if let error {
                logger.error("Send error: \(error)")
            }
        })
    }

    /// Send and track for retransmit.
    func sendTracked(_ data: Data) {
        let seq = data.readUInt16(at: ControlOffset.sequence)
        sentPackets.append((seq: seq, data: data))
        if sentPackets.count > maxRetransmitBuffer {
            sentPackets.removeFirst()
        }
        send(data)
    }

    // MARK: - Sequence

    func nextSequence() -> UInt16 {
        sequence &+= 1
        return sequence
    }

    // MARK: - Timer Cleanup

    func stopTimers() {
        pingTimer?.cancel()
        pingTimer = nil
        idleTimer?.cancel()
        idleTimer = nil
        resendTimer?.cancel()
        resendTimer = nil
    }

    // MARK: - Subclass Hooks

    /// Called when the base handshake completes (IAmReady received).
    func onReady() {}

    /// Called when the connection is lost or disconnected.
    func onDisconnected() {}

    deinit {
        stopTimers()
        connection?.cancel()
    }
}
