import Foundation
import Network
import os

private let logger = Logger(subsystem: "com.ic705cwlogger", category: "UDPControl")

/// Manages the control port (50001) connection.
/// Handles authentication handshake, token management, and keepalive.
public final class UDPControl: UDPBase {

    // MARK: - Configuration

    let userName: String
    let password: String
    let computerName: String

    // MARK: - Auth State

    private var innerSequence: UInt8 = 0
    private let tokReq: UInt16 = UInt16.random(in: 1...UInt16.max)
    private(set) var token: UInt32 = 0
    private(set) var haveToken = false

    // Capabilities received from radio
    public private(set) var radioCIVAddress: UInt8 = 0xA4  // default IC-705
    public private(set) var radioName: String = ""
    private(set) var radioMACAddr: Data = Data(count: 6)
    private(set) var commCap: UInt16 = 0
    public private(set) var remoteCIVPort: UInt16 = 50002
    public private(set) var remoteAudioPort: UInt16 = 50003
    public private(set) var localCIVPort: UInt16 = 0
    public private(set) var localAudioPort: UInt16 = 0

    private var tokenRenewTimer: DispatchSourceTimer?

    /// Called when fully authenticated and ready
    public var onAuthenticated: (() -> Void)?
    /// Called on disconnect
    public var onDisconnect: (() -> Void)?

    // MARK: - Init

    public init(host: String, port: UInt16 = 50001, userName: String, password: String) {
        self.userName = userName
        self.password = password
        self.computerName = "iPhone"
        super.init(host: host, port: port)
        allocateLocalStreamPorts()
    }

    private func allocateLocalStreamPorts() {
        func reservePort() -> UInt16 {
            let listener = try? NWListener(using: .udp, on: .any)
            defer { listener?.cancel() }
            listener?.start(queue: queue)
            return listener?.port?.rawValue ?? 0
        }

        localCIVPort = reservePort()
        localAudioPort = reservePort()
        if localCIVPort == 0 { localCIVPort = 50002 }
        if localAudioPort == 0 || localAudioPort == localCIVPort { localAudioPort = localCIVPort &+ 1 }
    }

    // MARK: - Handshake State Machine

    override func onReady() {
        logger.info("Control port ready, sending login")
        onStage?("Control socket ready; sending login")
        sendLogin()
    }

    private func sendLogin() {
        innerSequence &+= 1
        let packet = PacketBuilder.login(
            innerSeq: innerSequence,
            sendId: myId,
            recvId: remoteId,
            sequence: nextSequence(),
            tokReq: tokReq,
            userName: userName,
            password: password,
            computerName: computerName
        )
        sendTracked(packet)
        armResendTimer()
    }

    // MARK: - Data Packet Handling

    override func handleDataPacket(_ data: Data) {
        guard data.count >= Int(PacketSize.token) else {
            super.handleDataPacket(data)
            return
        }

        let code = data.readUInt16(at: TokenOffset.code)

        switch code {
        case TokenCode.loginResponse:
            handleLoginResponse(data)

        case TokenCode.capabilities:
            handleCapabilities(data)

        case TokenCode.tokenAckResponse:
            handleTokenResponse(data)

        case TokenCode.connInfoFromRadio:
            handleConnInfoFromRadio(data)

        case TokenCode.status:
            handleStatus(data)

        default:
            logger.debug("Unknown token code: 0x\(String(code, radix: 16))")
        }
    }

    // MARK: - Login Response

    private func handleLoginResponse(_ data: Data) {
        guard data.count >= Int(PacketSize.loginResponse) else { return }
        cancelResendTimer()

        // Extract token
        token = data.readUInt32(at: TokenOffset.token)
        logger.info("Login successful, token=\(self.token)")
        onStage?("Login accepted; token received")

        // Send token acknowledge
        sendTokenAcknowledge()
    }

    private func sendTokenAcknowledge() {
        innerSequence &+= 1
        onStage?("Sending token acknowledge")
        let packet = PacketBuilder.tokenAcknowledge(
            innerSeq: innerSequence,
            sendId: myId,
            recvId: remoteId,
            sequence: nextSequence(),
            tokReq: tokReq,
            token: token
        )
        sendTracked(packet)
        armResendTimer()
    }

    // MARK: - Capabilities

    private func handleCapabilities(_ data: Data) {
        guard data.count >= Int(PacketSize.capabilities) else { return }
        cancelResendTimer()

        haveToken = true

        // Extract radio info
        radioCIVAddress = data[CapabilitiesOffset.civAddr]
        radioMACAddr = data.subdata(in: CapabilitiesOffset.macAddr..<CapabilitiesOffset.macAddr + 6)
        commCap = data.readUInt16(at: TokenOffset.commCap)

        // Extract radio name
        let nameData = data.subdata(in: CapabilitiesOffset.radioName..<CapabilitiesOffset.radioName + 16)
        radioName = String(data: nameData, encoding: .utf8)?
            .trimmingCharacters(in: .controlCharacters.union(.init(charactersIn: "\0"))) ?? "Unknown"

        logger.info("Radio: \(self.radioName), CI-V: 0x\(String(self.radioCIVAddress, radix: 16))")
        onStage?("Capabilities received from \(radioName)")

        // Send ConnInfo
        sendConnInfo()
    }

    private func sendConnInfo() {
        innerSequence &+= 1
        onStage?("Sending ConnInfo with local CI-V port \(localCIVPort)")
        let packet = PacketBuilder.connInfo(
            innerSeq: innerSequence,
            sendId: myId,
            recvId: remoteId,
            sequence: nextSequence(),
            tokReq: tokReq,
            token: token,
            commCap: commCap,
            macAddr: radioMACAddr,
            radioName: radioName,
            userName: userName,
            serialPort: localCIVPort,
            audioPort: localAudioPort
        )
        sendTracked(packet)

        // Start ping timer and token renewal
        startPingTimer()
        startTokenRenewTimer()
    }

    // MARK: - Token Response (renew/remove)

    private func handleTokenResponse(_ data: Data) {
        let res = data.readUInt16(at: TokenOffset.res)
        switch res {
        case TokenRes.renew:
            logger.debug("Token renewed")
        case TokenRes.remove:
            logger.info("Token removed")
            haveToken = false
        default:
            break
        }
        onStage?("Token response received (res=0x\(String(res, radix: 16)))")
    }

    // MARK: - ConnInfo/Status

    private func handleConnInfoFromRadio(_ data: Data) {
        logger.debug("Received ConnInfo from radio")
        onStage?("Radio acknowledged ConnInfo")
    }

    private func handleStatus(_ data: Data) {
        guard data.count >= Int(PacketSize.status) else { return }
        remoteCIVPort = data.readUInt16BE(at: 0x42)
        remoteAudioPort = data.readUInt16BE(at: 0x46)
        if remoteCIVPort == 0 { remoteCIVPort = 50002 }
        if remoteAudioPort == 0 { remoteAudioPort = 50003 }
        isConnected = true
        logger.info("Received status from radio, remote CI-V port=\(self.remoteCIVPort)")
        onStage?("Control status received; remote CI-V port \(remoteCIVPort)")
        DispatchQueue.main.async { [weak self] in
            self?.onAuthenticated?()
        }
    }

    // MARK: - Token Renewal

    private func startTokenRenewTimer() {
        tokenRenewTimer?.cancel()
        tokenRenewTimer = DispatchSource.makeTimerSource(queue: queue)
        tokenRenewTimer?.schedule(
            deadline: .now() + Timing.tokenRenewInterval,
            repeating: Timing.tokenRenewInterval
        )
        tokenRenewTimer?.setEventHandler { [weak self] in
            self?.renewToken()
        }
        tokenRenewTimer?.resume()
    }

    private func renewToken() {
        guard haveToken else { return }
        innerSequence &+= 1
        let packet = PacketBuilder.tokenRenew(
            innerSeq: innerSequence,
            sendId: myId,
            recvId: remoteId,
            sequence: nextSequence(),
            tokReq: tokReq,
            token: token
        )
        sendTracked(packet)
        logger.debug("Token renew sent")
    }

    // MARK: - Disconnect

    public override func disconnect() {
        tokenRenewTimer?.cancel()
        tokenRenewTimer = nil

        if haveToken {
            innerSequence &+= 1
            let removePacket = PacketBuilder.tokenRemove(
                innerSeq: innerSequence,
                sendId: myId,
                recvId: remoteId,
                sequence: nextSequence(),
                tokReq: tokReq,
                token: token
            )
            sendTracked(removePacket)
        }

        super.disconnect()
    }

    override func onDisconnected() {
        tokenRenewTimer?.cancel()
        tokenRenewTimer = nil
        haveToken = false
        token = 0

        DispatchQueue.main.async { [weak self] in
            self?.onDisconnect?()
        }
    }

    deinit {
        tokenRenewTimer?.cancel()
    }
}
