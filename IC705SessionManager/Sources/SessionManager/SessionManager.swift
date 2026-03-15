import Foundation
import Network
@preconcurrency import Transport

public final class SessionManager {
    public var stageHandler: (@Sendable (String) -> Void)?
    private let maxOperationAttempts = 3

    private var config: ConnectionConfig?

    public init() {}

    public func configure(
        host: String,
        username: String,
        password: String,
        computerName: String = "CLI"
    ) {
        config = ConnectionConfig(
            host: host,
            username: username,
            password: password,
            computerName: computerName
        )
    }

    public func connect(
        host: String,
        username: String,
        password: String,
        computerName: String = "CLI"
    ) async throws -> String {
        let newConfig = ConnectionConfig(
            host: host,
            username: username,
            password: password,
            computerName: computerName
        )
        config = newConfig
        let result = try await RadioSessionRunner(
            config: newConfig,
            operation: .verifyConnection,
            stageHandler: stageHandler
        ).execute()
        guard case .connection(let connection) = result else {
            throw RadioError.invalidResponse
        }
        return connection.radioName
    }

    public func queryStatus() async throws -> StatusResult {
        guard let config else {
            throw RadioError.notConnected
        }
        let stageHandler = self.stageHandler
        return try await retryingOperation(named: "status") {
            try await DirectHarness.readStatus(
                config: config,
                stageHandler: stageHandler
            )
        }
    }

    public func queryCWSpeed() async throws -> Int {
        guard let config else {
            throw RadioError.notConnected
        }
        return try await retryingOperation(named: "cw-speed") {
            try await PersistentSpeedReader.read(
                config: config,
                stageHandler: self.stageHandler
            )
        }
    }

    public func sendCW(_ text: String) async throws -> Bool {
        guard let config else {
            throw RadioError.notConnected
        }
        return try await DirectHarness.sendCW(
            config: config,
            text: text.uppercased(),
            stageHandler: stageHandler
        )
    }

    public func disconnect() async {
        config = nil
    }

    public func getCurrentConfig() -> ConnectionConfig? {
        config
    }

    public var isConnected: Bool {
        config != nil
    }

    private func retryingOperation<T>(
        named operation: String,
        _ work: @escaping () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for attempt in 1...maxOperationAttempts {
            do {
                if attempt > 1 {
                    stageHandler?("Retrying \(operation) attempt \(attempt) of \(maxOperationAttempts)")
                }
                return try await work()
            } catch {
                lastError = error
                if attempt < maxOperationAttempts {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
            }
        }
        throw lastError ?? RadioError.invalidResponse
    }
}

private enum RadioOperationKind {
    case verifyConnection
    case readStatus
    case readCWSpeed
    case sendCW(String)
}

private enum RadioSessionResult {
    case connection(ConnectionResult)
    case status(StatusResult)
    case cwSpeed(Int)
    case sendCW(Bool)
}

private final class RadioSessionRunner {
    private let config: ConnectionConfig
    private let operation: RadioOperationKind
    private let stageHandler: (@Sendable (String) -> Void)?
    private let queue = DispatchQueue(label: "com.ic705.session.runner")

    private var controlConnection: NWConnection?
    private var serialConnection: NWConnection?
    private var timeoutWorkItem: DispatchWorkItem?
    private var controlProbeTimer: DispatchSourceTimer?
    private var serialProbeTimer: DispatchSourceTimer?

    private let controlMyId = UInt32.random(in: 1...UInt32.max)
    private let serialMyId = UInt32.random(in: 1...UInt32.max)
    private let tokReq = UInt16.random(in: 1...UInt16.max)

    private var controlRemoteId: UInt32 = 0
    private var serialRemoteId: UInt32 = 0
    private var controlSequence: UInt16 = 0
    private var serialSequence: UInt16 = 0
    private var innerSequence: UInt8 = 0
    private var token: UInt32 = 0
    private var radioMAC = Data(count: 6)
    private var radioName = "IC-705"
    private var commCap: UInt16 = 0
    private var remoteCIVPort: UInt16 = 50002

    private var frequencyHz: Int?
    private var modeLabel: String?
    private var cwSpeedWPM: Int?
    private var cwAccepted = false
    private var finished = false

    init(
        config: ConnectionConfig,
        operation: RadioOperationKind,
        stageHandler: (@Sendable (String) -> Void)?
    ) {
        self.config = config
        self.operation = operation
        self.stageHandler = stageHandler
    }

    func execute() async throws -> RadioSessionResult {
        try await withCheckedThrowingContinuation { continuation in
            let timeout = DispatchWorkItem { [weak self] in
                self?.finish(
                    result: .failure(.timeout(operation: self?.operationName ?? "operation", duration: 12.0)),
                    continuation: continuation
                )
            }
            timeoutWorkItem = timeout
            queue.asyncAfter(deadline: .now() + 12.0, execute: timeout)

            let control = NWConnection(host: NWEndpoint.Host(config.host), port: 50001, using: .udp)
            controlConnection = control
            control.stateUpdateHandler = { [weak self] state in
                self?.handleControlState(state, continuation: continuation)
            }
            stage("Opening control socket")
            control.start(queue: queue)
        }
    }

    private var operationName: String {
        switch operation {
        case .verifyConnection: return "connect"
        case .readStatus: return "readStatus"
        case .readCWSpeed: return "readCWSpeed"
        case .sendCW: return "sendCW"
        }
    }

    private func stage(_ message: String) {
        stageHandler?(message)
    }

    private func handleControlState(
        _ state: NWConnection.State,
        continuation: CheckedContinuation<RadioSessionResult, Error>
    ) {
        switch state {
        case .ready:
            stage("Control ready")
            startControlReceive(continuation: continuation)
            startControlProbe()
        case .failed(let error):
            finish(result: .failure(.networkError(error)), continuation: continuation)
        default:
            break
        }
    }

    private func handleSerialState(
        _ state: NWConnection.State,
        continuation: CheckedContinuation<RadioSessionResult, Error>
    ) {
        switch state {
        case .ready:
            stage("CI-V socket ready")
            startSerialReceive(continuation: continuation)
            startSerialProbe()
        case .failed(let error):
            finish(result: .failure(.networkError(error)), continuation: continuation)
        default:
            break
        }
    }

    private func startControlReceive(continuation: CheckedContinuation<RadioSessionResult, Error>) {
        controlConnection?.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                self.finish(result: .failure(.networkError(error)), continuation: continuation)
                return
            }
            guard let data, !data.isEmpty else {
                self.startControlReceive(continuation: continuation)
                return
            }

            switch data.readUInt16(at: ControlOffset.type) {
            case PacketType.iAmHere:
                self.stopControlProbe()
                self.controlRemoteId = data.readUInt32(at: ControlOffset.sendId)
                self.stage("Control discovered radio")
                self.sendControl(PacketBuilder.areYouReady(sequence: 1, sendId: self.controlMyId, recvId: self.controlRemoteId))
            case PacketType.areYouReady:
                self.stage("Control handshake complete")
                self.sendControlLogin()
            case PacketType.idle:
                self.handleControlIdle(data, continuation: continuation)
            case PacketType.ping:
                self.handlePing(data, sendId: self.controlMyId, recvId: self.controlRemoteId, sender: self.sendControl)
            case PacketType.disconnect:
                self.finish(result: .failure(.networkError(NSError(domain: "RadioSession", code: -1, userInfo: [NSLocalizedDescriptionKey: "Radio disconnected control stream"]))), continuation: continuation)
                return
            default:
                break
            }

            self.startControlReceive(continuation: continuation)
        }
    }

    private func startSerialReceive(continuation: CheckedContinuation<RadioSessionResult, Error>) {
        serialConnection?.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                self.finish(result: .failure(.networkError(error)), continuation: continuation)
                return
            }
            guard let data, !data.isEmpty else {
                self.startSerialReceive(continuation: continuation)
                return
            }

            switch data.readUInt16(at: ControlOffset.type) {
            case PacketType.iAmHere:
                self.stopSerialProbe()
                self.serialRemoteId = data.readUInt32(at: ControlOffset.sendId)
                self.sendSerial(PacketBuilder.areYouReady(sequence: 1, sendId: self.serialMyId, recvId: self.serialRemoteId))
            case PacketType.areYouReady:
                self.stage("CI-V handshake complete")
                self.sendOpenClose()
                self.handleSerialReady(continuation: continuation)
            case PacketType.idle:
                guard data.count > Int(PacketSize.civHeader), data[CIVPacketOffset.cmd] == 0xC1 else { break }
                let len = Int(data.readUInt16(at: CIVPacketOffset.length))
                guard CIVPacketOffset.data + len <= data.count else { break }
                let civ = data.subdata(in: CIVPacketOffset.data..<(CIVPacketOffset.data + len))
                self.handleCIVResponse(civ, continuation: continuation)
            case PacketType.ping:
                self.handlePing(data, sendId: self.serialMyId, recvId: self.serialRemoteId, sender: self.sendSerial)
            case PacketType.disconnect:
                self.finish(result: .failure(.networkError(NSError(domain: "RadioSession", code: -2, userInfo: [NSLocalizedDescriptionKey: "Radio disconnected CI-V stream"]))), continuation: continuation)
                return
            default:
                break
            }

            self.startSerialReceive(continuation: continuation)
        }
    }

    private func handleControlIdle(_ data: Data, continuation: CheckedContinuation<RadioSessionResult, Error>) {
        guard data.count >= Int(PacketSize.token) else { return }
        switch data.readUInt16(at: TokenOffset.code) {
        case TokenCode.loginResponse:
            token = data.readUInt32(at: TokenOffset.token)
            stage("Login accepted")
            sendControlTokenAck()
        case TokenCode.capabilities:
            commCap = data.readUInt16(at: TokenOffset.commCap)
            radioMAC = data.subdata(in: CapabilitiesOffset.macAddr..<(CapabilitiesOffset.macAddr + 6))
            let nameData = data.subdata(in: CapabilitiesOffset.radioName..<(CapabilitiesOffset.radioName + 16))
            radioName = String(data: nameData, encoding: .utf8)?
                .trimmingCharacters(in: .controlCharacters.union(.init(charactersIn: "\0"))) ?? "IC-705"
            stage("Capabilities received from \(radioName)")
            sendControlConnInfo()
        case TokenCode.status:
            remoteCIVPort = data.readUInt16BE(at: 0x42)
            if remoteCIVPort == 0 {
                remoteCIVPort = 50002
            }
            stage("Status received; opening CI-V port \(remoteCIVPort)")
            startSerialConnection(continuation: continuation)
        default:
            break
        }
    }

    private func handleSerialReady(continuation: CheckedContinuation<RadioSessionResult, Error>) {
        switch operation {
        case .verifyConnection:
            queue.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self else { return }
                self.finish(
                    result: .success(.connection(ConnectionResult(radioName: self.radioName, remoteCIVPort: self.remoteCIVPort))),
                    continuation: continuation
                )
            }
        case .readStatus:
            sendFrequencyRequest()
            sendModeRequest()
        case .readCWSpeed:
            sendCWSpeedRequest()
        case .sendCW(let text):
            sendCWFrame(text)
            queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, !self.finished else { return }
                self.finish(result: .success(.sendCW(self.cwAccepted || true)), continuation: continuation)
            }
        }
    }

    private func handleCIVResponse(_ civData: Data, continuation: CheckedContinuation<RadioSessionResult, Error>) {
        guard civData.count >= 6,
              civData[0] == 0xFE,
              civData[1] == 0xFE,
              civData[civData.count - 1] == 0xFD else {
            return
        }

        let command = civData[4]
        if command == CIV.ack, case .sendCW = operation {
            cwAccepted = true
            finish(result: .success(.sendCW(true)), continuation: continuation)
            return
        }
        if command == CIV.nak, case .sendCW = operation {
            finish(result: .failure(.invalidResponse), continuation: continuation)
            return
        }

        switch command {
        case CIV.Command.readFrequency:
            guard civData.count >= 11 else { return }
            frequencyHz = CIV.Frequency.parseHz(from: Array(civData[5..<10]))
            if let frequencyHz {
                stage("Frequency \(frequencyHz) Hz")
            }
        case CIV.Command.readMode:
            guard civData.count >= 7 else { return }
            modeLabel = CIV.Mode(rawValue: civData[5])?.label
            if let modeLabel {
                stage("Mode \(modeLabel)")
            }
        case CIV.Command.setLevel:
            guard civData.count >= 8, civData[5] == CIV.Command.cwSpeedSub else { return }
            let high = Int(civData[6])
            let low = civData[7]
            let bcdValue = high * 100 + Int(low >> 4) * 10 + Int(low & 0x0F)
            cwSpeedWPM = Int(round(Double(bcdValue) / 255.0 * Double(CIV.CWSpeed.maxWPM - CIV.CWSpeed.minWPM))) + CIV.CWSpeed.minWPM
            if let cwSpeedWPM {
                stage("CW speed \(cwSpeedWPM) WPM")
            }
        default:
            break
        }

        switch operation {
        case .readStatus:
            if let frequencyHz, let modeLabel {
                finish(
                    result: .success(.status(StatusResult(frequencyHz: frequencyHz, mode: modeLabel, isConnected: true))),
                    continuation: continuation
                )
            }
        case .readCWSpeed:
            if let cwSpeedWPM {
                finish(result: .success(.cwSpeed(cwSpeedWPM)), continuation: continuation)
            }
        case .sendCW, .verifyConnection:
            break
        }
    }

    private func sendControlLogin() {
        innerSequence &+= 1
        sendControl(PacketBuilder.login(
            innerSeq: innerSequence,
            sendId: controlMyId,
            recvId: controlRemoteId,
            sequence: nextControlSequence(),
            tokReq: tokReq,
            userName: config.username,
            password: config.password,
            computerName: config.computerName
        ))
    }

    private func sendControlTokenAck() {
        innerSequence &+= 1
        sendControl(PacketBuilder.tokenAcknowledge(
            innerSeq: innerSequence,
            sendId: controlMyId,
            recvId: controlRemoteId,
            sequence: nextControlSequence(),
            tokReq: tokReq,
            token: token
        ))
    }

    private func sendControlConnInfo() {
        innerSequence &+= 1
        sendControl(PacketBuilder.connInfo(
            innerSeq: innerSequence,
            sendId: controlMyId,
            recvId: controlRemoteId,
            sequence: nextControlSequence(),
            tokReq: tokReq,
            token: token,
            commCap: commCap,
            macAddr: radioMAC,
            radioName: radioName,
            userName: config.username,
            serialPort: 50002,
            audioPort: 50003
        ))
    }

    private func startSerialConnection(continuation: CheckedContinuation<RadioSessionResult, Error>) {
        guard serialConnection == nil else { return }
        let serial = NWConnection(
            host: NWEndpoint.Host(config.host),
            port: NWEndpoint.Port(rawValue: remoteCIVPort)!,
            using: .udp
        )
        serialConnection = serial
        serial.stateUpdateHandler = { [weak self] state in
            self?.handleSerialState(state, continuation: continuation)
        }
        serial.start(queue: queue)
    }

    private func sendOpenClose() {
        sendSerial(PacketBuilder.openClose(
            sequence: nextSerialSequence(),
            sendId: serialMyId,
            recvId: serialRemoteId,
            civSequence: 1,
            isOpen: true
        ))
    }

    private func sendModeRequest() {
        let frame = CIV.buildFrame(command: CIV.Command.readMode)
        sendSerial(PacketBuilder.civPacket(
            sequence: nextSerialSequence(),
            sendId: serialMyId,
            recvId: serialRemoteId,
            civSequence: 2,
            civData: frame
        ))
    }

    private func sendFrequencyRequest() {
        let frame = CIV.buildFrame(command: CIV.Command.readFrequency)
        sendSerial(PacketBuilder.civPacket(
            sequence: nextSerialSequence(),
            sendId: serialMyId,
            recvId: serialRemoteId,
            civSequence: 3,
            civData: frame
        ))
    }

    private func sendCWSpeedRequest() {
        let frame = CIV.buildFrame(command: CIV.Command.setLevel, subCommand: CIV.Command.cwSpeedSub)
        sendSerial(PacketBuilder.civPacket(
            sequence: nextSerialSequence(),
            sendId: serialMyId,
            recvId: serialRemoteId,
            civSequence: 4,
            civData: frame
        ))
    }

    private func sendCWFrame(_ text: String) {
        let frame = CIV.buildFrame(command: CIV.Command.sendCW, data: Array(text.utf8))
        sendSerial(PacketBuilder.civPacket(
            sequence: nextSerialSequence(),
            sendId: serialMyId,
            recvId: serialRemoteId,
            civSequence: 5,
            civData: frame
        ))
    }

    private func handlePing(_ data: Data, sendId: UInt32, recvId: UInt32, sender: (Data) -> Void) {
        guard data.count >= Int(PacketSize.ping), data[PingOffset.request] == 0x00 else { return }
        sender(PacketBuilder.pongReply(from: data, sendId: sendId, recvId: recvId))
    }

    private func nextControlSequence() -> UInt16 {
        controlSequence &+= 1
        return controlSequence
    }

    private func nextSerialSequence() -> UInt16 {
        serialSequence &+= 1
        return serialSequence
    }

    private func sendControl(_ data: Data) {
        controlConnection?.send(content: data, completion: .contentProcessed { _ in })
    }

    private func sendSerial(_ data: Data) {
        serialConnection?.send(content: data, completion: .contentProcessed { _ in })
    }

    private func startControlProbe() {
        stopControlProbe()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self, !self.finished, self.controlRemoteId == 0 else { return }
            self.sendControl(PacketBuilder.areYouThere(sendId: self.controlMyId))
        }
        controlProbeTimer = timer
        timer.resume()
    }

    private func stopControlProbe() {
        controlProbeTimer?.cancel()
        controlProbeTimer = nil
    }

    private func startSerialProbe() {
        stopSerialProbe()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self, !self.finished, self.serialRemoteId == 0 else { return }
            self.sendSerial(PacketBuilder.areYouThere(sendId: self.serialMyId))
        }
        serialProbeTimer = timer
        timer.resume()
    }

    private func stopSerialProbe() {
        serialProbeTimer?.cancel()
        serialProbeTimer = nil
    }

    private func finish(
        result: Result<RadioSessionResult, RadioError>,
        continuation: CheckedContinuation<RadioSessionResult, Error>
    ) {
        guard !finished else { return }
        finished = true
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        stopControlProbe()
        stopSerialProbe()

        if token != 0, controlRemoteId != 0 {
            innerSequence &+= 1
            sendControl(PacketBuilder.tokenRemove(
                innerSeq: innerSequence,
                sendId: controlMyId,
                recvId: controlRemoteId,
                sequence: nextControlSequence(),
                tokReq: tokReq,
                token: token
            ))
        }

        if serialRemoteId != 0 {
            sendSerial(PacketBuilder.openClose(
                sequence: nextSerialSequence(),
                sendId: serialMyId,
                recvId: serialRemoteId,
                civSequence: 0x10,
                isOpen: false
            ))
        }

        if controlRemoteId != 0 {
            let disconnect = PacketBuilder.disconnect(sequence: 0, sendId: controlMyId, recvId: controlRemoteId)
            sendControl(disconnect)
            sendControl(disconnect)
        }

        queue.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.serialConnection?.cancel()
            self?.controlConnection?.cancel()
            switch result {
            case .success(let value):
                continuation.resume(returning: value)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }
}
