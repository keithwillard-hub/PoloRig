import Foundation
import Network
@preconcurrency import Transport

private let disconnectGraceSeconds: TimeInterval = 1.0

enum DirectHarness {
    static func readStatus(
        config: ConnectionConfig,
        stageHandler: (@Sendable (String) -> Void)?
    ) async throws -> StatusResult {
        try await withCheckedThrowingContinuation { continuation in
            var reader: HarnessStatusReader? = HarnessStatusReader(config: config, stageHandler: stageHandler)
            reader?.start { result in
                defer { reader = nil }
                switch result {
                case .success(let value):
                    continuation.resume(returning: value)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func readCWSpeed(
        config: ConnectionConfig,
        stageHandler: (@Sendable (String) -> Void)?
    ) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            var reader: HarnessCWSpeedReader? = HarnessCWSpeedReader(config: config, stageHandler: stageHandler)
            reader?.start { result in
                defer { reader = nil }
                switch result {
                case .success(let value):
                    continuation.resume(returning: value)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func sendCW(
        config: ConnectionConfig,
        text: String,
        stageHandler: (@Sendable (String) -> Void)?
    ) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            var sender: HarnessCWSender? = HarnessCWSender(config: config, text: text, stageHandler: stageHandler)
            sender?.start { result in
                defer { sender = nil }
                switch result {
                case .success(let value):
                    continuation.resume(returning: value)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private enum HarnessSessionSupport {
    static func sendControlLogin(
        innerSequence: inout UInt8,
        controlMyId: UInt32,
        controlRemoteId: UInt32,
        controlSequence: inout UInt16,
        tokReq: UInt16,
        username: String,
        password: String,
        sendControl: (Data) -> Void
    ) {
        innerSequence &+= 1
        sendControl(PacketBuilder.login(
            innerSeq: innerSequence,
            sendId: controlMyId,
            recvId: controlRemoteId,
            sequence: nextSequence(&controlSequence),
            tokReq: tokReq,
            userName: username,
            password: password,
            computerName: "iPhone"
        ))
    }

    static func sendControlTokenAck(
        innerSequence: inout UInt8,
        controlMyId: UInt32,
        controlRemoteId: UInt32,
        controlSequence: inout UInt16,
        tokReq: UInt16,
        token: UInt32,
        sendControl: (Data) -> Void
    ) {
        innerSequence &+= 1
        sendControl(PacketBuilder.tokenAcknowledge(
            innerSeq: innerSequence,
            sendId: controlMyId,
            recvId: controlRemoteId,
            sequence: nextSequence(&controlSequence),
            tokReq: tokReq,
            token: token
        ))
    }

    static func sendControlConnInfo(
        innerSequence: inout UInt8,
        controlMyId: UInt32,
        controlRemoteId: UInt32,
        controlSequence: inout UInt16,
        tokReq: UInt16,
        token: UInt32,
        commCap: UInt16,
        radioMAC: Data,
        radioName: String,
        username: String,
        sendControl: (Data) -> Void
    ) {
        innerSequence &+= 1
        sendControl(PacketBuilder.connInfo(
            innerSeq: innerSequence,
            sendId: controlMyId,
            recvId: controlRemoteId,
            sequence: nextSequence(&controlSequence),
            tokReq: tokReq,
            token: token,
            commCap: commCap,
            macAddr: radioMAC,
            radioName: radioName,
            userName: username,
            serialPort: 50002,
            audioPort: 50003
        ))
    }

    static func startSerialConnection(
        host: String,
        remoteCIVPort: UInt16,
        queue: DispatchQueue,
        assign: (NWConnection) -> Void,
        handleState: @escaping (NWConnection.State) -> Void
    ) {
        let serial = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: remoteCIVPort)!,
            using: .udp
        )
        assign(serial)
        serial.stateUpdateHandler = handleState
        serial.start(queue: queue)
    }

    static func sendOpenClose(
        serialSequence: inout UInt16,
        serialMyId: UInt32,
        serialRemoteId: UInt32,
        civSequence: UInt16,
        isOpen: Bool,
        sendSerial: (Data) -> Void
    ) {
        sendSerial(PacketBuilder.openClose(
            sequence: nextSequence(&serialSequence),
            sendId: serialMyId,
            recvId: serialRemoteId,
            civSequence: civSequence,
            isOpen: isOpen
        ))
    }

    static func handlePing(
        _ data: Data,
        sendId: UInt32,
        recvId: UInt32,
        sender: (Data) -> Void
    ) {
        guard data.count >= Int(PacketSize.ping), data[PingOffset.request] == 0x00 else { return }
        sender(PacketBuilder.pongReply(from: data, sendId: sendId, recvId: recvId))
    }

    static func finish(
        queue: DispatchQueue,
        timeoutWorkItem: inout DispatchWorkItem?,
        controlConnection: NWConnection?,
        serialConnection: NWConnection?,
        controlRemoteId: UInt32,
        serialRemoteId: UInt32,
        controlMyId: UInt32,
        serialMyId: UInt32,
        innerSequence: inout UInt8,
        controlSequence: inout UInt16,
        serialSequence: inout UInt16,
        tokReq: UInt16,
        token: UInt32,
        completion: @escaping () -> Void,
        sendControl: (Data) -> Void,
        sendSerial: (Data) -> Void
    ) {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil

        if token != 0, controlRemoteId != 0 {
            innerSequence &+= 1
            sendControl(PacketBuilder.tokenRemove(
                innerSeq: innerSequence,
                sendId: controlMyId,
                recvId: controlRemoteId,
                sequence: nextSequence(&controlSequence),
                tokReq: tokReq,
                token: token
            ))
        }

        if serialRemoteId != 0 {
            sendSerial(PacketBuilder.openClose(
                sequence: nextSequence(&serialSequence),
                sendId: serialMyId,
                recvId: serialRemoteId,
                civSequence: 4,
                isOpen: false
            ))
        }

        if controlRemoteId != 0 {
            let disconnect = PacketBuilder.disconnect(sequence: 0, sendId: controlMyId, recvId: controlRemoteId)
            sendControl(disconnect)
            sendControl(disconnect)
        }

        queue.asyncAfter(deadline: .now() + disconnectGraceSeconds) {
            serialConnection?.cancel()
            controlConnection?.cancel()
            completion()
        }
    }

    static func nextSequence(_ value: inout UInt16) -> UInt16 {
        value &+= 1
        return value
    }
}

private final class HarnessStatusReader {
    private let config: ConnectionConfig
    private let stageHandler: (@Sendable (String) -> Void)?
    private let queue = DispatchQueue(label: "com.ic705.harness.status")

    private var controlConnection: NWConnection?
    private var serialConnection: NWConnection?
    private var timeoutWorkItem: DispatchWorkItem?
    private var retryWorkItems: [DispatchWorkItem] = []
    private var openRetryTimer: DispatchSourceTimer?
    private var completion: ((Result<StatusResult, RadioError>) -> Void)?
    private var finished = false
    private var frequencyHz: Int?
    private var modeLabel: String?
    private var serialTrafficObserved = false

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
    private var serialCIVSequence: UInt16 = 1

    init(config: ConnectionConfig, stageHandler: (@Sendable (String) -> Void)?) {
        self.config = config
        self.stageHandler = stageHandler
    }

    func start(completion: @escaping (Result<StatusResult, RadioError>) -> Void) {
        self.completion = completion
        stageHandler?("Starting direct status reader")

        timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.finish(.failure(.timeout(operation: "readStatus", duration: 12.0)))
        }
        if let timeoutWorkItem {
            queue.asyncAfter(deadline: .now() + 12.0, execute: timeoutWorkItem)
        }

        let control = NWConnection(host: NWEndpoint.Host(config.host), port: 50001, using: .udp)
        controlConnection = control
        control.stateUpdateHandler = { [weak self] state in
            self?.handleControlState(state)
        }
        control.start(queue: queue)
    }

    private func handleControlState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            stageHandler?("Direct status control ready")
            startControlReceive()
            sendControl(PacketBuilder.areYouThere(sendId: controlMyId))
        case .failed(let error):
            finish(.failure(.networkError(error)))
        default:
            break
        }
    }

    private func handleSerialState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            stageHandler?("Direct status serial ready")
            startSerialReceive()
            sendSerial(PacketBuilder.areYouThere(sendId: serialMyId))
        case .failed(let error):
            finish(.failure(.networkError(error)))
        default:
            break
        }
    }

    private func startControlReceive() {
        controlConnection?.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                self.finish(.failure(.networkError(error)))
                return
            }
            guard let data, !data.isEmpty else {
                self.startControlReceive()
                return
            }

            let type = data.readUInt16(at: ControlOffset.type)
            switch type {
            case PacketType.iAmHere:
                self.stageHandler?("Direct status control discovered radio")
                self.controlRemoteId = data.readUInt32(at: ControlOffset.sendId)
                self.sendControl(PacketBuilder.areYouReady(sequence: 1, sendId: self.controlMyId, recvId: self.controlRemoteId))
            case PacketType.areYouReady:
                self.stageHandler?("Direct status control handshake complete")
                self.sendControlLogin()
            case PacketType.idle:
                self.handleControlIdle(data)
            case PacketType.ping:
                self.handlePing(data, sendId: self.controlMyId, recvId: self.controlRemoteId, sender: self.sendControl)
            default:
                break
            }

            self.startControlReceive()
        }
    }

    private func startSerialReceive() {
        serialConnection?.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                self.finish(.failure(.networkError(error)))
                return
            }
            guard let data, !data.isEmpty else {
                self.startSerialReceive()
                return
            }

            let type = data.readUInt16(at: ControlOffset.type)
            switch type {
            case PacketType.iAmHere:
                self.stageHandler?("Direct status CI-V discovered radio")
                self.serialRemoteId = data.readUInt32(at: ControlOffset.sendId)
                self.sendSerial(PacketBuilder.areYouReady(sequence: 1, sendId: self.serialMyId, recvId: self.serialRemoteId))
            case PacketType.areYouReady:
                self.stageHandler?("Direct status CI-V handshake complete")
                self.sendOpenClose()
                self.startOpenCloseRetries()
                self.sendFrequencyRequest()
                self.sendModeRequest()
                self.scheduleStatusRetry(after: 0.25)
                self.scheduleStatusRetry(after: 0.75)
                self.scheduleStatusRetry(after: 1.50)
                self.scheduleStatusRetry(after: 2.50)
            case PacketType.idle:
                guard data.count > Int(PacketSize.civHeader), data[CIVPacketOffset.cmd] == 0xC1 else { break }
                let len = Int(data.readUInt16(at: CIVPacketOffset.length))
                guard CIVPacketOffset.data + len <= data.count else { break }
                let civ = data.subdata(in: CIVPacketOffset.data..<(CIVPacketOffset.data + len))
                self.serialTrafficObserved = true
                self.stopOpenCloseRetries()
                let civHex = civ.map { String(format: "%02X", $0) }.joined(separator: " ")
                self.stageHandler?("Direct status CI-V payload [\(civHex)]")
                self.handleCIVResponse(civ)
            case PacketType.ping:
                self.handlePing(data, sendId: self.serialMyId, recvId: self.serialRemoteId, sender: self.sendSerial)
            default:
                break
            }

            self.startSerialReceive()
        }
    }

    private func handleControlIdle(_ data: Data) {
        guard data.count >= Int(PacketSize.token) else { return }
        switch data.readUInt16(at: TokenOffset.code) {
        case TokenCode.loginResponse:
            stageHandler?("Direct status login accepted")
            token = data.readUInt32(at: TokenOffset.token)
            sendControlTokenAck()
        case TokenCode.capabilities:
            stageHandler?("Direct status capabilities received")
            commCap = data.readUInt16(at: TokenOffset.commCap)
            radioMAC = data.subdata(in: CapabilitiesOffset.macAddr..<(CapabilitiesOffset.macAddr + 6))
            let nameData = data.subdata(in: CapabilitiesOffset.radioName..<(CapabilitiesOffset.radioName + 16))
            radioName = String(data: nameData, encoding: .utf8)?
                .trimmingCharacters(in: .controlCharacters.union(.init(charactersIn: "\0"))) ?? "IC-705"
            sendControlConnInfo()
        case TokenCode.status:
            remoteCIVPort = data.readUInt16BE(at: 0x42)
            if remoteCIVPort == 0 { remoteCIVPort = 50002 }
            stageHandler?("Direct status received CI-V port \(remoteCIVPort)")
            startSerialConnection()
        default:
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
            computerName: "iPhone"
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

    private func startSerialConnection() {
        guard serialConnection == nil else { return }
        let serial = NWConnection(host: NWEndpoint.Host(config.host), port: NWEndpoint.Port(rawValue: remoteCIVPort)!, using: .udp)
        serialConnection = serial
        serial.stateUpdateHandler = { [weak self] state in
            self?.handleSerialState(state)
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
        let civFrame = CIV.buildFrame(command: CIV.Command.readMode)
        let civHex = civFrame.map { String(format: "%02X", $0) }.joined(separator: " ")
        stageHandler?("Direct status mode request [\(civHex)]")
        sendSerial(PacketBuilder.civPacket(
            sequence: nextSerialSequence(),
            sendId: serialMyId,
            recvId: serialRemoteId,
            civSequence: 2,
            civData: civFrame
        ))
    }

    private func sendFrequencyRequest() {
        let civFrame = CIV.buildFrame(command: CIV.Command.readFrequency)
        let civHex = civFrame.map { String(format: "%02X", $0) }.joined(separator: " ")
        stageHandler?("Direct status frequency request [\(civHex)]")
        sendSerial(PacketBuilder.civPacket(
            sequence: nextSerialSequence(),
            sendId: serialMyId,
            recvId: serialRemoteId,
            civSequence: 3,
            civData: civFrame
        ))
    }

    private func scheduleStatusRetry(after delay: TimeInterval) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.finished else { return }
            if self.frequencyHz != nil && self.modeLabel != nil { return }
            self.stageHandler?("Direct status retry after \(String(format: "%.2f", delay))s")
            if !self.serialTrafficObserved {
                self.sendOpenClose()
            }
            if self.frequencyHz == nil {
                self.sendFrequencyRequest()
            }
            if self.modeLabel == nil {
                self.sendModeRequest()
            }
        }
        retryWorkItems.append(workItem)
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func startOpenCloseRetries() {
        guard openRetryTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.10, repeating: 0.10)
        timer.setEventHandler { [weak self] in
            guard let self, !self.finished, !self.serialTrafficObserved else {
                self?.stopOpenCloseRetries()
                return
            }
            self.sendOpenClose()
        }
        openRetryTimer = timer
        timer.resume()
    }

    private func stopOpenCloseRetries() {
        openRetryTimer?.cancel()
        openRetryTimer = nil
    }

    private func handleCIVResponse(_ civData: Data) {
        guard civData.count >= 7, civData[0] == 0xFE, civData[1] == 0xFE, civData[civData.count - 1] == 0xFD else { return }

        switch civData[4] {
        case CIV.Command.readMode:
            modeLabel = CIV.Mode(rawValue: civData[5])?.label
            stageHandler?("Direct status received mode \(modeLabel ?? "unknown")")
        case CIV.Command.readFrequency:
            guard civData.count >= 11 else { return }
            frequencyHz = CIV.Frequency.parseHz(from: Array(civData[5..<10]))
            if let frequencyHz {
                stageHandler?("Direct status received frequency \(frequencyHz) Hz")
            }
        default:
            return
        }

        if let frequencyHz, let modeLabel {
            finish(.success(StatusResult(frequencyHz: frequencyHz, mode: modeLabel, isConnected: true)))
        }
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

    private func finish(_ result: Result<StatusResult, RadioError>) {
        guard !finished else { return }
        finished = true
        retryWorkItems.forEach { $0.cancel() }
        retryWorkItems.removeAll()
        stopOpenCloseRetries()
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil

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
                civSequence: 4,
                isOpen: false
            ))
        }

        if controlRemoteId != 0 {
            let disconnect = PacketBuilder.disconnect(sequence: 0, sendId: controlMyId, recvId: controlRemoteId)
            sendControl(disconnect)
            sendControl(disconnect)
        }

        queue.asyncAfter(deadline: .now() + disconnectGraceSeconds) { [weak self] in
            self?.serialConnection?.cancel()
            self?.controlConnection?.cancel()
            self?.completion?(result)
            self?.completion = nil
        }
    }
}

private final class HarnessCWSpeedReader {
    private let config: ConnectionConfig
    private let stageHandler: (@Sendable (String) -> Void)?
    private let queue = DispatchQueue(label: "com.ic705.harness.speed")

    private var controlConnection: NWConnection?
    private var serialConnection: NWConnection?
    private var timeoutWorkItem: DispatchWorkItem?
    private var retryWorkItems: [DispatchWorkItem] = []
    private var openRetryTimer: DispatchSourceTimer?
    private var completion: ((Result<Int, RadioError>) -> Void)?
    private var finished = false
    private var finishingScheduled = false
    private var cwSpeedWPM: Int?
    private var frequencyHz: Int?
    private var modeLabel: String?
    private var warmupObserved = false
    private var speedRequested = false
    private var serialTrafficObserved = false

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
    private var serialCIVSequence: UInt16 = 1

    init(config: ConnectionConfig, stageHandler: (@Sendable (String) -> Void)?) {
        self.config = config
        self.stageHandler = stageHandler
    }

    func start(completion: @escaping (Result<Int, RadioError>) -> Void) {
        self.completion = completion
        stageHandler?("Starting direct CW speed reader")

        timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.finish(.failure(.timeout(operation: "readCWSpeed", duration: 12.0)))
        }
        if let timeoutWorkItem {
            queue.asyncAfter(deadline: .now() + 12.0, execute: timeoutWorkItem)
        }

        let control = NWConnection(host: NWEndpoint.Host(config.host), port: 50001, using: .udp)
        controlConnection = control
        control.stateUpdateHandler = { [weak self] state in
            self?.handleControlState(state)
        }
        control.start(queue: queue)
    }

    private func handleControlState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            stageHandler?("Direct speed control ready")
            startControlReceive()
            sendControl(PacketBuilder.areYouThere(sendId: controlMyId))
        case .failed(let error):
            finish(.failure(.networkError(error)))
        default:
            break
        }
    }

    private func handleSerialState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            stageHandler?("Direct speed serial ready")
            startSerialReceive()
            sendSerial(PacketBuilder.areYouThere(sendId: serialMyId))
        case .failed(let error):
            finish(.failure(.networkError(error)))
        default:
            break
        }
    }

    private func startControlReceive() {
        controlConnection?.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                self.finish(.failure(.networkError(error)))
                return
            }
            guard let data, !data.isEmpty else {
                self.startControlReceive()
                return
            }
            switch data.readUInt16(at: ControlOffset.type) {
            case PacketType.iAmHere:
                self.stageHandler?("Direct speed control discovered radio")
                self.controlRemoteId = data.readUInt32(at: ControlOffset.sendId)
                self.sendControl(PacketBuilder.areYouReady(sequence: 1, sendId: self.controlMyId, recvId: self.controlRemoteId))
            case PacketType.areYouReady:
                self.stageHandler?("Direct speed control handshake complete")
                self.sendControlLogin()
            case PacketType.idle:
                self.handleControlIdle(data)
            case PacketType.ping:
                self.handlePing(data, sendId: self.controlMyId, recvId: self.controlRemoteId, sender: self.sendControl)
            default:
                break
            }
            self.startControlReceive()
        }
    }

    private func startSerialReceive() {
        serialConnection?.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                self.finish(.failure(.networkError(error)))
                return
            }
            guard let data, !data.isEmpty else {
                self.startSerialReceive()
                return
            }

            switch data.readUInt16(at: ControlOffset.type) {
            case PacketType.iAmHere:
                self.stageHandler?("Direct speed CI-V discovered radio")
                self.serialRemoteId = data.readUInt32(at: ControlOffset.sendId)
                self.sendSerial(PacketBuilder.areYouReady(sequence: 1, sendId: self.serialMyId, recvId: self.serialRemoteId))
            case PacketType.areYouReady:
                self.stageHandler?("Direct speed CI-V handshake complete")
                self.sendOpenClose()
                self.startOpenCloseRetries()
                self.sendWarmupRequests()
                self.scheduleWarmupRetry(after: 0.25)
                self.scheduleWarmupRetry(after: 0.75)
                self.scheduleWarmupRetry(after: 1.50)
                self.scheduleCWSpeedRetry(after: 0.90)
                self.scheduleCWSpeedRetry(after: 1.80)
                self.scheduleCWSpeedRetry(after: 3.00)
            case PacketType.idle:
                guard data.count > Int(PacketSize.civHeader), data[CIVPacketOffset.cmd] == 0xC1 else { break }
                let len = Int(data.readUInt16(at: CIVPacketOffset.length))
                guard CIVPacketOffset.data + len <= data.count else { break }
                let civ = data.subdata(in: CIVPacketOffset.data..<(CIVPacketOffset.data + len))
                self.serialTrafficObserved = true
                self.stopOpenCloseRetries()
                let civHex = civ.map { String(format: "%02X", $0) }.joined(separator: " ")
                self.stageHandler?("Direct speed CI-V payload [\(civHex)]")
                self.handleCIVResponse(civ)
            case PacketType.ping:
                self.handlePing(data, sendId: self.serialMyId, recvId: self.serialRemoteId, sender: self.sendSerial)
            default:
                break
            }
            self.startSerialReceive()
        }
    }

    private func handleControlIdle(_ data: Data) {
        guard data.count >= Int(PacketSize.token) else { return }
        switch data.readUInt16(at: TokenOffset.code) {
        case TokenCode.loginResponse:
            stageHandler?("Direct speed login accepted")
            token = data.readUInt32(at: TokenOffset.token)
            sendControlTokenAck()
        case TokenCode.capabilities:
            stageHandler?("Direct speed capabilities received")
            commCap = data.readUInt16(at: TokenOffset.commCap)
            radioMAC = data.subdata(in: CapabilitiesOffset.macAddr..<(CapabilitiesOffset.macAddr + 6))
            let nameData = data.subdata(in: CapabilitiesOffset.radioName..<(CapabilitiesOffset.radioName + 16))
            radioName = String(data: nameData, encoding: .utf8)?
                .trimmingCharacters(in: .controlCharacters.union(.init(charactersIn: "\0"))) ?? "IC-705"
            sendControlConnInfo()
        case TokenCode.status:
            remoteCIVPort = data.readUInt16BE(at: 0x42)
            if remoteCIVPort == 0 { remoteCIVPort = 50002 }
            stageHandler?("Direct speed received CI-V port \(remoteCIVPort)")
            startSerialConnection()
        default:
            break
        }
    }

    private func sendControlLogin() {
        innerSequence &+= 1
        sendControl(PacketBuilder.login(innerSeq: innerSequence, sendId: controlMyId, recvId: controlRemoteId, sequence: nextControlSequence(), tokReq: tokReq, userName: config.username, password: config.password, computerName: "iPhone"))
    }

    private func sendControlTokenAck() {
        innerSequence &+= 1
        sendControl(PacketBuilder.tokenAcknowledge(innerSeq: innerSequence, sendId: controlMyId, recvId: controlRemoteId, sequence: nextControlSequence(), tokReq: tokReq, token: token))
    }

    private func sendControlConnInfo() {
        innerSequence &+= 1
        sendControl(PacketBuilder.connInfo(innerSeq: innerSequence, sendId: controlMyId, recvId: controlRemoteId, sequence: nextControlSequence(), tokReq: tokReq, token: token, commCap: commCap, macAddr: radioMAC, radioName: radioName, userName: config.username, serialPort: 50002, audioPort: 50003))
    }

    private func startSerialConnection() {
        guard serialConnection == nil else { return }
        let serial = NWConnection(host: NWEndpoint.Host(config.host), port: NWEndpoint.Port(rawValue: remoteCIVPort)!, using: .udp)
        serialConnection = serial
        serial.stateUpdateHandler = { [weak self] state in
            self?.handleSerialState(state)
        }
        serial.start(queue: queue)
    }

    private func sendOpenClose() {
        sendSerial(PacketBuilder.openClose(sequence: nextSerialSequence(), sendId: serialMyId, recvId: serialRemoteId, civSequence: 1, isOpen: true))
    }

    private func sendCWSpeedRequest() {
        speedRequested = true
        let civFrame = CIV.buildFrame(command: CIV.Command.setLevel, subCommand: CIV.Command.cwSpeedSub)
        let civHex = civFrame.map { String(format: "%02X", $0) }.joined(separator: " ")
        stageHandler?("Direct speed request [\(civHex)]")
        sendSerial(PacketBuilder.civPacket(sequence: nextSerialSequence(), sendId: serialMyId, recvId: serialRemoteId, civSequence: 4, civData: civFrame))
    }

    private func sendWarmupModeRequest() {
        let civFrame = CIV.buildFrame(command: CIV.Command.readMode)
        let civHex = civFrame.map { String(format: "%02X", $0) }.joined(separator: " ")
        stageHandler?("Direct speed warmup mode [\(civHex)]")
        sendSerial(PacketBuilder.civPacket(sequence: nextSerialSequence(), sendId: serialMyId, recvId: serialRemoteId, civSequence: 2, civData: civFrame))
    }

    private func sendWarmupFrequencyRequest() {
        let civFrame = CIV.buildFrame(command: CIV.Command.readFrequency)
        let civHex = civFrame.map { String(format: "%02X", $0) }.joined(separator: " ")
        stageHandler?("Direct speed warmup frequency [\(civHex)]")
        sendSerial(PacketBuilder.civPacket(sequence: nextSerialSequence(), sendId: serialMyId, recvId: serialRemoteId, civSequence: 3, civData: civFrame))
    }

    private func sendWarmupRequests() {
        sendWarmupFrequencyRequest()
        sendWarmupModeRequest()
    }

    private func scheduleCWSpeedRetry(after delay: TimeInterval) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.finished, self.speedRequested, self.cwSpeedWPM == nil else { return }
            self.stageHandler?("Direct speed retry after \(String(format: "%.2f", delay))s")
            self.sendCWSpeedRequest()
        }
        retryWorkItems.append(workItem)
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func scheduleWarmupRetry(after delay: TimeInterval) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.finished, !self.warmupObserved else { return }
            self.stageHandler?("Direct speed warmup retry after \(String(format: "%.2f", delay))s")
            if !self.serialTrafficObserved {
                self.sendOpenClose()
            }
            self.sendWarmupRequests()
        }
        retryWorkItems.append(workItem)
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func startOpenCloseRetries() {
        guard openRetryTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.10, repeating: 0.10)
        timer.setEventHandler { [weak self] in
            guard let self, !self.finished, !self.serialTrafficObserved else {
                self?.stopOpenCloseRetries()
                return
            }
            self.sendOpenClose()
        }
        openRetryTimer = timer
        timer.resume()
    }

    private func stopOpenCloseRetries() {
        openRetryTimer?.cancel()
        openRetryTimer = nil
    }

    private func handleCIVResponse(_ civData: Data) {
        guard civData.count >= 8, civData[0] == 0xFE, civData[1] == 0xFE, civData[civData.count - 1] == 0xFD else { return }
        switch civData[4] {
        case CIV.Command.readFrequency:
            warmupObserved = true
            guard civData.count >= 11 else { return }
            frequencyHz = CIV.Frequency.parseHz(from: Array(civData[5..<10]))
            if let frequencyHz {
                stageHandler?("Direct speed warmup frequency response \(frequencyHz) Hz")
            }
            requestSpeedIfWarmupComplete()
        case CIV.Command.readMode:
            warmupObserved = true
            guard civData.count >= 7 else { return }
            modeLabel = CIV.Mode(rawValue: civData[5])?.label
            if let modeLabel {
                stageHandler?("Direct speed warmup mode response \(modeLabel)")
            }
            requestSpeedIfWarmupComplete()
        case CIV.Command.setLevel:
            guard civData.count >= 8, civData[5] == CIV.Command.cwSpeedSub else { return }
            let high = Int(civData[6])
            let low = civData[7]
            let bcdValue = high * 100 + Int(low >> 4) * 10 + Int(low & 0x0F)
            cwSpeedWPM = Int(round(Double(bcdValue) / 255.0 * Double(CIV.CWSpeed.maxWPM - CIV.CWSpeed.minWPM))) + CIV.CWSpeed.minWPM
            if let cwSpeedWPM {
                stageHandler?("Direct speed received \(cwSpeedWPM) WPM")
                finishAfterSettle(.success(cwSpeedWPM))
            }
        default:
            return
        }
    }

    private func requestSpeedIfWarmupComplete() {
        guard !speedRequested, frequencyHz != nil, modeLabel != nil else { return }
        stageHandler?("Direct speed warmup complete; requesting CW speed")
        sendCWSpeedRequest()
    }

    private func finishAfterSettle(_ result: Result<Int, RadioError>) {
        guard !finishingScheduled else { return }
        finishingScheduled = true
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.finish(result)
        }
    }

    private func handlePing(_ data: Data, sendId: UInt32, recvId: UInt32, sender: (Data) -> Void) {
        guard data.count >= Int(PacketSize.ping), data[PingOffset.request] == 0x00 else { return }
        sender(PacketBuilder.pongReply(from: data, sendId: sendId, recvId: recvId))
    }

    private func nextControlSequence() -> UInt16 { controlSequence &+= 1; return controlSequence }
    private func nextSerialSequence() -> UInt16 { serialSequence &+= 1; return serialSequence }
    private func sendControl(_ data: Data) { controlConnection?.send(content: data, completion: .contentProcessed { _ in }) }
    private func sendSerial(_ data: Data) { serialConnection?.send(content: data, completion: .contentProcessed { _ in }) }

    private func finish(_ result: Result<Int, RadioError>) {
        guard !finished else { return }
        finished = true
        retryWorkItems.forEach { $0.cancel() }
        retryWorkItems.removeAll()
        stopOpenCloseRetries()
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        if token != 0, controlRemoteId != 0 {
            innerSequence &+= 1
            sendControl(PacketBuilder.tokenRemove(innerSeq: innerSequence, sendId: controlMyId, recvId: controlRemoteId, sequence: nextControlSequence(), tokReq: tokReq, token: token))
        }
        if serialRemoteId != 0 {
            sendSerial(PacketBuilder.openClose(sequence: nextSerialSequence(), sendId: serialMyId, recvId: serialRemoteId, civSequence: 4, isOpen: false))
        }
        if controlRemoteId != 0 {
            let disconnect = PacketBuilder.disconnect(sequence: 0, sendId: controlMyId, recvId: controlRemoteId)
            sendControl(disconnect)
            sendControl(disconnect)
        }
        queue.asyncAfter(deadline: .now() + disconnectGraceSeconds) { [weak self] in
            self?.serialConnection?.cancel()
            self?.controlConnection?.cancel()
            self?.completion?(result)
            self?.completion = nil
        }
    }
}

private final class HarnessCWSender {
    private let config: ConnectionConfig
    private let text: String
    private let stageHandler: (@Sendable (String) -> Void)?
    private let queue = DispatchQueue(label: "com.ic705.harness.cw")

    private var controlConnection: NWConnection?
    private var serialConnection: NWConnection?
    private var timeoutWorkItem: DispatchWorkItem?
    private var completion: ((Result<Bool, RadioError>) -> Void)?
    private var finished = false

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

    init(config: ConnectionConfig, text: String, stageHandler: (@Sendable (String) -> Void)?) {
        self.config = config
        self.text = text.uppercased()
        self.stageHandler = stageHandler
    }

    func start(completion: @escaping (Result<Bool, RadioError>) -> Void) {
        self.completion = completion
        stageHandler?("Starting direct CW sender")

        timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.finish(.failure(.timeout(operation: "sendCW", duration: 12.0)))
        }
        if let timeoutWorkItem {
            queue.asyncAfter(deadline: .now() + 12.0, execute: timeoutWorkItem)
        }

        let control = NWConnection(host: NWEndpoint.Host(config.host), port: 50001, using: .udp)
        controlConnection = control
        control.stateUpdateHandler = { [weak self] state in
            self?.handleControlState(state)
        }
        control.start(queue: queue)
    }

    private func handleControlState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            startControlReceive()
            sendControl(PacketBuilder.areYouThere(sendId: controlMyId))
        case .failed(let error):
            finish(.failure(.networkError(error)))
        default:
            break
        }
    }

    private func handleSerialState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            startSerialReceive()
            sendSerial(PacketBuilder.areYouThere(sendId: serialMyId))
        case .failed(let error):
            finish(.failure(.networkError(error)))
        default:
            break
        }
    }

    private func startControlReceive() {
        controlConnection?.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                self.finish(.failure(.networkError(error)))
                return
            }
            guard let data, !data.isEmpty else {
                self.startControlReceive()
                return
            }

            switch data.readUInt16(at: ControlOffset.type) {
            case PacketType.iAmHere:
                self.stageHandler?("Direct CW control discovered radio")
                self.controlRemoteId = data.readUInt32(at: ControlOffset.sendId)
                self.sendControl(PacketBuilder.areYouReady(sequence: 1, sendId: self.controlMyId, recvId: self.controlRemoteId))
            case PacketType.areYouReady:
                self.stageHandler?("Direct CW control handshake complete")
                self.sendControlLogin()
            case PacketType.idle:
                self.handleControlIdle(data)
            case PacketType.ping:
                self.handlePing(data, sendId: self.controlMyId, recvId: self.controlRemoteId, sender: self.sendControl)
            default:
                break
            }

            self.startControlReceive()
        }
    }

    private func startSerialReceive() {
        serialConnection?.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                self.finish(.failure(.networkError(error)))
                return
            }
            guard let data, !data.isEmpty else {
                self.startSerialReceive()
                return
            }

            switch data.readUInt16(at: ControlOffset.type) {
            case PacketType.iAmHere:
                self.stageHandler?("Direct CW CI-V discovered radio")
                self.serialRemoteId = data.readUInt32(at: ControlOffset.sendId)
                self.sendSerial(PacketBuilder.areYouReady(sequence: 1, sendId: self.serialMyId, recvId: self.serialRemoteId))
            case PacketType.areYouReady:
                self.stageHandler?("Direct CW CI-V handshake complete")
                self.sendOpenClose()
                self.sendCW()
                self.queue.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    self?.finish(.success(true))
                }
            case PacketType.ping:
                self.handlePing(data, sendId: self.serialMyId, recvId: self.serialRemoteId, sender: self.sendSerial)
            default:
                break
            }

            self.startSerialReceive()
        }
    }

    private func handleControlIdle(_ data: Data) {
        guard data.count >= Int(PacketSize.token) else { return }
        switch data.readUInt16(at: TokenOffset.code) {
        case TokenCode.loginResponse:
            stageHandler?("Direct CW login accepted")
            token = data.readUInt32(at: TokenOffset.token)
            sendControlTokenAck()
        case TokenCode.capabilities:
            stageHandler?("Direct CW capabilities received")
            commCap = data.readUInt16(at: TokenOffset.commCap)
            radioMAC = data.subdata(in: CapabilitiesOffset.macAddr..<(CapabilitiesOffset.macAddr + 6))
            let nameData = data.subdata(in: CapabilitiesOffset.radioName..<(CapabilitiesOffset.radioName + 16))
            radioName = String(data: nameData, encoding: .utf8)?
                .trimmingCharacters(in: .controlCharacters.union(.init(charactersIn: "\0"))) ?? "IC-705"
            sendControlConnInfo()
        case TokenCode.status:
            remoteCIVPort = data.readUInt16BE(at: 0x42)
            if remoteCIVPort == 0 { remoteCIVPort = 50002 }
            stageHandler?("Direct CW received CI-V port \(remoteCIVPort)")
            startSerialConnection()
        default:
            break
        }
    }

    private func sendControlLogin() {
        innerSequence &+= 1
        sendControl(PacketBuilder.login(innerSeq: innerSequence, sendId: controlMyId, recvId: controlRemoteId, sequence: nextControlSequence(), tokReq: tokReq, userName: config.username, password: config.password, computerName: "iPhone"))
    }

    private func sendControlTokenAck() {
        innerSequence &+= 1
        sendControl(PacketBuilder.tokenAcknowledge(innerSeq: innerSequence, sendId: controlMyId, recvId: controlRemoteId, sequence: nextControlSequence(), tokReq: tokReq, token: token))
    }

    private func sendControlConnInfo() {
        innerSequence &+= 1
        sendControl(PacketBuilder.connInfo(innerSeq: innerSequence, sendId: controlMyId, recvId: controlRemoteId, sequence: nextControlSequence(), tokReq: tokReq, token: token, commCap: commCap, macAddr: radioMAC, radioName: radioName, userName: config.username, serialPort: 50002, audioPort: 50003))
    }

    private func startSerialConnection() {
        guard serialConnection == nil else { return }
        let serial = NWConnection(host: NWEndpoint.Host(config.host), port: NWEndpoint.Port(rawValue: remoteCIVPort)!, using: .udp)
        serialConnection = serial
        serial.stateUpdateHandler = { [weak self] state in
            self?.handleSerialState(state)
        }
        serial.start(queue: queue)
    }

    private func sendOpenClose() {
        sendSerial(PacketBuilder.openClose(sequence: nextSerialSequence(), sendId: serialMyId, recvId: serialRemoteId, civSequence: 1, isOpen: true))
    }

    private func sendCW() {
        let civFrame = CIV.buildFrame(command: CIV.Command.sendCW, data: Array(text.utf8))
        sendSerial(PacketBuilder.civPacket(sequence: nextSerialSequence(), sendId: serialMyId, recvId: serialRemoteId, civSequence: 2, civData: civFrame))
    }

    private func handlePing(_ data: Data, sendId: UInt32, recvId: UInt32, sender: (Data) -> Void) {
        guard data.count >= Int(PacketSize.ping), data[PingOffset.request] == 0x00 else { return }
        sender(PacketBuilder.pongReply(from: data, sendId: sendId, recvId: recvId))
    }

    private func nextControlSequence() -> UInt16 { controlSequence &+= 1; return controlSequence }
    private func nextSerialSequence() -> UInt16 { serialSequence &+= 1; return serialSequence }
    private func sendControl(_ data: Data) { controlConnection?.send(content: data, completion: .contentProcessed { _ in }) }
    private func sendSerial(_ data: Data) { serialConnection?.send(content: data, completion: .contentProcessed { _ in }) }

    private func finish(_ result: Result<Bool, RadioError>) {
        guard !finished else { return }
        finished = true
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        if token != 0, controlRemoteId != 0 {
            innerSequence &+= 1
            sendControl(PacketBuilder.tokenRemove(innerSeq: innerSequence, sendId: controlMyId, recvId: controlRemoteId, sequence: nextControlSequence(), tokReq: tokReq, token: token))
        }
        if serialRemoteId != 0 {
            sendSerial(PacketBuilder.openClose(sequence: nextSerialSequence(), sendId: serialMyId, recvId: serialRemoteId, civSequence: 4, isOpen: false))
        }
        if controlRemoteId != 0 {
            let disconnect = PacketBuilder.disconnect(sequence: 0, sendId: controlMyId, recvId: controlRemoteId)
            sendControl(disconnect)
            sendControl(disconnect)
        }
        queue.asyncAfter(deadline: .now() + disconnectGraceSeconds) { [weak self] in
            self?.serialConnection?.cancel()
            self?.controlConnection?.cancel()
            self?.completion?(result)
            self?.completion = nil
        }
    }
}
