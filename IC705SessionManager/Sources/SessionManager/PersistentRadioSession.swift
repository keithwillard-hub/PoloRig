import Foundation
@preconcurrency import Transport

public final class PersistentRadioSession {
    public var stageHandler: (@Sendable (String) -> Void)? {
        get { core.stageHandler }
        set { core.stageHandler = newValue }
    }

    private let core: PersistentRadioSessionCore

    public init(config: ConnectionConfig) {
        self.core = PersistentRadioSessionCore(config: config)
    }

    public func connect() async throws -> ConnectionResult {
        try await core.connect()
    }

    public func queryStatus() async throws -> StatusResult {
        try await core.queryStatus()
    }

    public func queryCWSpeed() async throws -> Int {
        try await core.queryCWSpeed()
    }

    public func sendCW(_ text: String) async throws -> Bool {
        try await core.sendCW(text.uppercased())
    }

    public func setCWSpeed(_ wpm: Int) async throws {
        try await core.setCWSpeed(wpm)
    }

    public func stopCW() async throws {
        try await core.stopCW()
    }

    public func disconnect() async {
        await core.disconnect()
    }
}

private final class PersistentRadioSessionCore: @unchecked Sendable {
    var stageHandler: (@Sendable (String) -> Void)?

    private enum SessionState {
        case disconnected
        case connecting
        case connected
        case disconnecting
    }

    private enum PendingOperation {
        case status
        case cwSpeedWarmup
        case cwSpeed
        case setCWSpeed(Int)
        case sendCW(String)
        case stopCW
    }

    private let config: ConnectionConfig
    private let queue = DispatchQueue(label: "com.ic705.session.persistent")

    private var control: UDPControl?
    private var serial: UDPSerial?
    private var state: SessionState = .disconnected

    private var connectContinuation: CheckedContinuation<ConnectionResult, Error>?
    private var operationContinuation: CheckedContinuation<OperationResult, Error>?
    private var disconnectContinuation: CheckedContinuation<Void, Never>?

    private var timeoutWorkItem: DispatchWorkItem?
    private var operationTimer: DispatchSourceTimer?
    private var pendingOperation: PendingOperation?

    private var radioName = "IC-705"
    private var frequencyHz: Int?
    private var modeLabel: String?
    private var cwSpeedWPM: Int?
    private var speedRequested = false
    private var cwSendQueued = false

    init(config: ConnectionConfig) {
        self.config = config
    }

    func connect() async throws -> ConnectionResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                switch self.state {
                case .connected:
                    continuation.resume(returning: ConnectionResult(
                        radioName: self.radioName,
                        remoteCIVPort: self.control?.remoteCIVPort ?? 50002
                    ))
                case .connecting:
                    continuation.resume(throwing: RadioError.radioBusy)
                case .disconnecting:
                    continuation.resume(throwing: RadioError.notConnected)
                case .disconnected:
                    self.startConnect(continuation)
                }
            }
        }
    }

    func queryStatus() async throws -> StatusResult {
        let result = try await beginOperation(.status, timeout: 12.0)
        guard case .status(let status) = result else {
            throw RadioError.invalidResponse
        }
        return status
    }

    func queryCWSpeed() async throws -> Int {
        let result = try await beginOperation(.cwSpeedWarmup, timeout: 16.0)
        guard case .cwSpeed(let speed) = result else {
            throw RadioError.invalidResponse
        }
        return speed
    }

    func sendCW(_ text: String) async throws -> Bool {
        let result = try await beginOperation(.sendCW(text), timeout: 10.0)
        guard case .sendCW(let success) = result else {
            throw RadioError.invalidResponse
        }
        return success
    }

    func setCWSpeed(_ wpm: Int) async throws {
        let result = try await beginOperation(.setCWSpeed(wpm), timeout: 10.0)
        guard case .setCWSpeed = result else {
            throw RadioError.invalidResponse
        }
    }

    func stopCW() async throws {
        let result = try await beginOperation(.stopCW, timeout: 10.0)
        guard case .stopCW = result else {
            throw RadioError.invalidResponse
        }
    }

    func disconnect() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.state == .disconnected {
                    continuation.resume()
                    return
                }
                self.startDisconnect(completion: continuation)
            }
        }
    }

    private func startConnect(_ continuation: CheckedContinuation<ConnectionResult, Error>) {
        guard connectContinuation == nil else {
            continuation.resume(throwing: RadioError.radioBusy)
            return
        }

        connectContinuation = continuation
        state = .connecting
        radioName = "IC-705"
        stageHandler?("Opening persistent control session")
        armTimeout(seconds: 15.0, operation: "connect") { [weak self] in
            self?.finishConnect(.failure(.timeout(operation: "connect", duration: 15.0)))
        }

        let control = UDPControl(
            host: config.host,
            userName: config.username,
            password: config.password,
            computerName: config.computerName
        )
        control.onStage = { [weak self] message in
            self?.stageHandler?("Control: \(message)")
        }
        control.onAuthenticated = { [weak self] in
            self?.queue.async {
                guard let self else { return }
                self.radioName = control.radioName
                self.stageHandler?("Connected to \(self.radioName); opening CI-V session")
                self.startSerial()
            }
        }
        control.onDisconnect = { [weak self] in
            self?.queue.async {
                self?.handleUnexpectedDisconnect()
            }
        }
        self.control = control
        control.connect()
    }

    private func startSerial() {
        guard let control else {
            finishConnect(.failure(.notConnected))
            return
        }

        let serial = UDPSerial(
            host: config.host,
            port: control.remoteCIVPort,
            localPort: control.localCIVPort
        )
        serial.onStage = { [weak self] message in
            self?.stageHandler?("Serial: \(message)")
        }
        serial.onCIVReceived = { [weak self] civData in
            self?.queue.async {
                self?.handleCIV(civData)
            }
        }
        serial.onSerialReady = { [weak self] in
            self?.queue.async {
                guard let self else { return }
                self.state = .connected
                self.finishConnect(.success(ConnectionResult(
                    radioName: self.radioName,
                    remoteCIVPort: control.remoteCIVPort
                )))
            }
        }
        self.serial = serial
        serial.connect()
    }

    private func finishConnect(_ result: Result<ConnectionResult, RadioError>) {
        cancelTimeout()
        guard let continuation = connectContinuation else { return }
        connectContinuation = nil

        switch result {
        case .success(let connection):
            continuation.resume(returning: connection)
        case .failure(let error):
            teardownTransport()
            state = .disconnected
            continuation.resume(throwing: error)
        }
    }

    private func beginOperation(_ operation: PendingOperation, timeout: TimeInterval) async throws -> OperationResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.state == .connected else {
                    continuation.resume(throwing: RadioError.notConnected)
                    return
                }
                guard self.pendingOperation == nil, self.operationContinuation == nil else {
                    continuation.resume(throwing: RadioError.radioBusy)
                    return
                }

                self.resetOperationState(for: operation)
                self.pendingOperation = operation
                self.operationContinuation = continuation
                self.armTimeout(seconds: timeout, operation: self.operationName(for: operation)) { [weak self] in
                    guard let self else { return }
                    self.finishOperation(.failure(.timeout(operation: self.operationName(for: operation), duration: timeout)))
                }
                self.startOperationTimer()
            }
        }
    }

    private func resetOperationState(for operation: PendingOperation) {
        frequencyHz = nil
        modeLabel = nil
        cwSpeedWPM = nil
        speedRequested = false
        cwSendQueued = false
        if case .sendCW = operation {
            serial?.flushQueue()
        }
    }

    private func startOperationTimer() {
        operationTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.5)
        timer.setEventHandler { [weak self] in
            self?.pollOperation()
        }
        operationTimer = timer
        timer.resume()
    }

    private func pollOperation() {
        guard state == .connected, let serial, let operation = pendingOperation else { return }
        guard !serial.isWaitingForReply, serial.queueDepth == 0 else { return }

        switch operation {
        case .status:
            if frequencyHz == nil {
                stageHandler?("Persistent status polling frequency")
                serial.sendCIV(data: CIV.buildFrame(command: CIV.Command.readFrequency), completion: nil)
            } else if modeLabel == nil {
                stageHandler?("Persistent status polling mode")
                serial.sendCIV(data: CIV.buildFrame(command: CIV.Command.readMode), completion: nil)
            }

        case .cwSpeedWarmup:
            if frequencyHz == nil {
                stageHandler?("Persistent speed warmup frequency")
                serial.sendCIV(data: CIV.buildFrame(command: CIV.Command.readFrequency), completion: nil)
            } else if modeLabel == nil {
                stageHandler?("Persistent speed warmup mode")
                serial.sendCIV(data: CIV.buildFrame(command: CIV.Command.readMode), completion: nil)
            } else {
                pendingOperation = .cwSpeed
            }

        case .cwSpeed:
            speedRequested = true
            stageHandler?("Persistent speed requesting CW speed")
            serial.sendCIV(
                data: CIV.buildFrame(command: CIV.Command.setLevel, subCommand: CIV.Command.cwSpeedSub),
                completion: nil
            )

        case .setCWSpeed(let wpm):
            let clamped = min(max(wpm, CIV.CWSpeed.minWPM), CIV.CWSpeed.maxWPM)
            let (high, low) = CIV.CWSpeed.wpmToValue(clamped)
            stageHandler?("Persistent set CW speed \(clamped) WPM")
            serial.sendCIV(
                data: CIV.buildFrame(
                    command: CIV.Command.setLevel,
                    subCommand: CIV.Command.cwSpeedSub,
                    data: [high, low]
                )
            ) { [weak self] success in
                self?.queue.async {
                    guard let self else { return }
                    guard success else {
                        self.finishOperation(.failure(.invalidResponse))
                        return
                    }
                    self.cwSpeedWPM = clamped
                    self.finishOperation(.success(.setCWSpeed(clamped)))
                }
            }

        case .sendCW(let text):
            guard !cwSendQueued else { return }
            cwSendQueued = true
            stageHandler?("Persistent send CW '\(text)'")
            serial.sendCIV(
                data: CIV.buildFrame(command: CIV.Command.sendCW, data: Array(text.utf8)),
                expectsReply: false
            ) { [weak self] success in
                self?.queue.async {
                    guard let self else { return }
                    guard success else {
                        self.finishOperation(.failure(.invalidResponse))
                        return
                    }
                    self.queue.asyncAfter(deadline: .now() + 0.8) {
                        self.finishOperation(.success(.sendCW(true)))
                    }
                }
            }

        case .stopCW:
            stageHandler?("Persistent stop CW")
            serial.sendCIV(
                data: CIV.buildFrame(command: CIV.Command.sendCW, data: [0xFF]),
                expectsReply: false
            ) { [weak self] success in
                self?.queue.async {
                    guard let self else { return }
                    guard success else {
                        self.finishOperation(.failure(.invalidResponse))
                        return
                    }
                    self.finishOperation(.success(.stopCW))
                }
            }
        }
    }

    private func handleCIV(_ civData: Data) {
        guard civData.count >= 6,
              civData[0] == 0xFE,
              civData[1] == 0xFE,
              civData[civData.count - 1] == 0xFD else {
            return
        }

        switch civData[4] {
        case CIV.Command.readFrequency:
            guard civData.count >= 11 else { return }
            frequencyHz = CIV.Frequency.parseHz(from: Array(civData[5..<10]))
            if let frequencyHz {
                stageHandler?("Persistent frequency \(frequencyHz) Hz")
                if case .status? = pendingOperation, let modeLabel {
                    finishOperation(.success(.status(StatusResult(
                        frequencyHz: frequencyHz,
                        mode: modeLabel,
                        isConnected: true
                    ))))
                }
            }

        case CIV.Command.readMode:
            guard civData.count >= 7 else { return }
            modeLabel = CIV.Mode(rawValue: civData[5])?.label
            if let modeLabel {
                stageHandler?("Persistent mode \(modeLabel)")
                if case .status? = pendingOperation, let frequencyHz {
                    finishOperation(.success(.status(StatusResult(
                        frequencyHz: frequencyHz,
                        mode: modeLabel,
                        isConnected: true
                    ))))
                }
            }

        case CIV.Command.setLevel:
            guard civData.count >= 8, civData[5] == CIV.Command.cwSpeedSub else { return }
            let high = Int(civData[6])
            let low = civData[7]
            let bcdValue = high * 100 + Int(low >> 4) * 10 + Int(low & 0x0F)
            let speed = Int(round(Double(bcdValue) / 255.0 * Double(CIV.CWSpeed.maxWPM - CIV.CWSpeed.minWPM))) + CIV.CWSpeed.minWPM
            cwSpeedWPM = speed
            stageHandler?("Persistent CW speed \(speed) WPM")
            if case .cwSpeed? = pendingOperation {
                finishOperation(.success(.cwSpeed(speed)))
            }

        default:
            break
        }

        if case .cwSpeedWarmup? = pendingOperation, frequencyHz != nil, modeLabel != nil {
            pendingOperation = .cwSpeed
        }
    }

    private func finishOperation(_ result: Result<OperationResult, RadioError>) {
        cancelTimeout()
        operationTimer?.cancel()
        operationTimer = nil

        guard let continuation = operationContinuation else { return }
        operationContinuation = nil
        pendingOperation = nil

        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func startDisconnect(completion: CheckedContinuation<Void, Never>) {
        disconnectContinuation = completion
        state = .disconnecting
        cancelTimeout()
        operationTimer?.cancel()
        operationTimer = nil
        pendingOperation = nil
        operationContinuation = nil

        serial?.requestClose()
        serial?.disconnect()
        control?.requestTokenRemove()
        control?.disconnect()

        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.teardownTransport()
            self.state = .disconnected
            self.disconnectContinuation?.resume()
            self.disconnectContinuation = nil
        }
    }

    private func teardownTransport() {
        serial = nil
        control = nil
    }

    private func handleUnexpectedDisconnect() {
        switch state {
        case .connecting:
            finishConnect(.failure(.radioBusy))
        case .connected:
            if operationContinuation != nil {
                finishOperation(.failure(.radioBusy))
            }
            teardownTransport()
            state = .disconnected
        case .disconnecting:
            teardownTransport()
            state = .disconnected
            disconnectContinuation?.resume()
            disconnectContinuation = nil
        case .disconnected:
            break
        }
    }

    private func armTimeout(
        seconds: TimeInterval,
        operation: String,
        handler: @escaping () -> Void
    ) {
        cancelTimeout()
        let workItem = DispatchWorkItem(block: handler)
        timeoutWorkItem = workItem
        stageHandler?("Timeout armed for \(operation) (\(seconds)s)")
        queue.asyncAfter(deadline: .now() + seconds, execute: workItem)
    }

    private func cancelTimeout() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
    }

    private func operationName(for operation: PendingOperation) -> String {
        switch operation {
        case .status:
            return "status"
        case .cwSpeedWarmup, .cwSpeed:
            return "cw-speed"
        case .sendCW:
            return "send-cw"
        case .setCWSpeed:
            return "set-cw-speed"
        case .stopCW:
            return "stop-cw"
        }
    }
}

private enum OperationResult {
    case status(StatusResult)
    case cwSpeed(Int)
    case setCWSpeed(Int)
    case sendCW(Bool)
    case stopCW
}
