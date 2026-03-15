import Foundation
@preconcurrency import Transport

public enum PersistentSequenceRunner {
    public static func run(
        config: ConnectionConfig,
        cwText: String,
        stageHandler: (@Sendable (String) -> Void)? = nil
    ) async throws -> SequenceResult {
        try await withCheckedThrowingContinuation { continuation in
            var runner: PersistentSequenceSession? = PersistentSequenceSession(
                config: config,
                cwText: cwText,
                stageHandler: stageHandler
            )
            runner?.start { result in
                defer { runner = nil }
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

private final class PersistentSequenceSession {
    private enum Phase {
        case connecting
        case waitingForSerial
        case readingSpeedWarmup
        case readingSpeed
        case readingStatus
        case sendingCW
        case disconnecting
        case finished
    }

    private let config: ConnectionConfig
    private let cwText: String
    private let stageHandler: (@Sendable (String) -> Void)?
    private let queue = DispatchQueue(label: "com.ic705.session.sequence")

    private var control: UDPControl?
    private var serial: UDPSerial?
    private var timeoutWorkItem: DispatchWorkItem?
    private var phaseTimer: DispatchSourceTimer?
    private var completion: ((Result<SequenceResult, RadioError>) -> Void)?
    private var finished = false
    private var phase: Phase = .connecting

    private var radioName = "IC-705"
    private var speedWarmupFrequencyHz: Int?
    private var speedWarmupMode: String?
    private var cwSpeedWPM: Int?
    private var statusFrequencyHz: Int?
    private var statusMode: String?
    private var cwSendQueued = false

    init(
        config: ConnectionConfig,
        cwText: String,
        stageHandler: (@Sendable (String) -> Void)?
    ) {
        self.config = config
        self.cwText = cwText.uppercased()
        self.stageHandler = stageHandler
    }

    func start(completion: @escaping (Result<SequenceResult, RadioError>) -> Void) {
        self.completion = completion
        stageHandler?("Starting persistent session sequence")

        timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.finish(.failure(.timeout(operation: "session-sequence", duration: 30.0)))
        }
        if let timeoutWorkItem {
            queue.asyncAfter(deadline: .now() + 30.0, execute: timeoutWorkItem)
        }

        let control = UDPControl(
            host: config.host,
            userName: config.username,
            password: config.password,
            computerName: "iPhone"
        )
        control.onStage = { [weak self] message in
            self?.stageHandler?("Control: \(message)")
        }
        control.onAuthenticated = { [weak self] in
            self?.queue.async {
                guard let self else { return }
                self.radioName = control.radioName
                self.phase = .waitingForSerial
                self.stageHandler?("Connected to \(self.radioName); opening persistent CI-V session")
                self.startSerial()
            }
        }
        control.onDisconnect = { [weak self] in
            self?.queue.async {
                guard let self, !self.finished, self.phase != .disconnecting else { return }
                self.finish(.failure(.radioBusy))
            }
        }
        self.control = control
        control.connect()
    }

    private func startSerial() {
        guard let control else { return }
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
                self.phase = .readingSpeedWarmup
                self.stageHandler?("Persistent serial ready; beginning sequence")
                self.startPhaseTimer()
            }
        }
        self.serial = serial
        serial.connect()
    }

    private func startPhaseTimer() {
        phaseTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.5)
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        phaseTimer = timer
        timer.resume()
    }

    private func tick() {
        guard let serial, !finished else { return }
        guard !serial.isWaitingForReply, serial.queueDepth == 0 else { return }

        switch phase {
        case .readingSpeedWarmup:
            stageHandler?("Sequence step: read CW speed")
            if speedWarmupFrequencyHz == nil {
                serial.sendCIV(data: CIV.buildFrame(command: CIV.Command.readFrequency), completion: nil)
            } else if speedWarmupMode == nil {
                serial.sendCIV(data: CIV.buildFrame(command: CIV.Command.readMode), completion: nil)
            } else {
                phase = .readingSpeed
            }

        case .readingSpeed:
            stageHandler?("Sequence requesting CW speed")
            serial.sendCIV(data: CIV.buildFrame(command: CIV.Command.setLevel, subCommand: CIV.Command.cwSpeedSub), completion: nil)

        case .readingStatus:
            stageHandler?("Sequence step: read frequency and mode")
            if statusFrequencyHz == nil {
                serial.sendCIV(data: CIV.buildFrame(command: CIV.Command.readFrequency), completion: nil)
            } else if statusMode == nil {
                serial.sendCIV(data: CIV.buildFrame(command: CIV.Command.readMode), completion: nil)
            }

        case .sendingCW:
            guard !cwSendQueued else { return }
            cwSendQueued = true
            stageHandler?("Sequence step: send CW '\(cwText)'")
            serial.sendCIV(
                data: CIV.buildFrame(command: CIV.Command.sendCW, data: Array(cwText.utf8)),
                expectsReply: false
            ) { [weak self] success in
                self?.queue.async {
                    guard let self else { return }
                    if success {
                        self.phase = .disconnecting
                        self.queue.asyncAfter(deadline: .now() + 0.8) {
                            self.finish(.success(SequenceResult(
                                radioName: self.radioName,
                                cwSpeedWPM: self.cwSpeedWPM ?? 0,
                                frequencyHz: self.statusFrequencyHz ?? 0,
                                mode: self.statusMode ?? "Unknown",
                                cwSent: true
                            )))
                        }
                    } else {
                        self.finish(.failure(.invalidResponse))
                    }
                }
            }

        case .connecting, .waitingForSerial, .disconnecting, .finished:
            break
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
            let hz = CIV.Frequency.parseHz(from: Array(civData[5..<10]))
            if phase == .readingSpeedWarmup {
                speedWarmupFrequencyHz = hz
                if let hz {
                    stageHandler?("Sequence warmup frequency \(hz) Hz")
                }
            } else if phase == .readingStatus {
                statusFrequencyHz = hz
                if let hz {
                    stageHandler?("Sequence status frequency \(hz) Hz")
                }
                maybeAdvanceStatus()
            }

        case CIV.Command.readMode:
            guard civData.count >= 7 else { return }
            let mode = CIV.Mode(rawValue: civData[5])?.label
            if phase == .readingSpeedWarmup {
                speedWarmupMode = mode
                if let mode {
                    stageHandler?("Sequence warmup mode \(mode)")
                }
            } else if phase == .readingStatus {
                statusMode = mode
                if let mode {
                    stageHandler?("Sequence status mode \(mode)")
                }
                maybeAdvanceStatus()
            }

        case CIV.Command.setLevel:
            guard civData.count >= 8, civData[5] == CIV.Command.cwSpeedSub else { return }
            let high = Int(civData[6])
            let low = civData[7]
            let bcdValue = high * 100 + Int(low >> 4) * 10 + Int(low & 0x0F)
            let speed = Int(round(Double(bcdValue) / 255.0 * Double(CIV.CWSpeed.maxWPM - CIV.CWSpeed.minWPM))) + CIV.CWSpeed.minWPM
            cwSpeedWPM = speed
            stageHandler?("Sequence CW speed \(speed) WPM")
            if phase == .readingSpeed {
                phase = .readingStatus
                statusFrequencyHz = nil
                statusMode = nil
            }

        default:
            break
        }

        if phase == .readingSpeedWarmup, speedWarmupFrequencyHz != nil, speedWarmupMode != nil {
            phase = .readingSpeed
        }
    }

    private func maybeAdvanceStatus() {
        guard phase == .readingStatus, statusFrequencyHz != nil, statusMode != nil else { return }
        phase = .sendingCW
    }

    private func finish(_ result: Result<SequenceResult, RadioError>) {
        guard !finished else { return }
        finished = true
        phase = .finished

        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        phaseTimer?.cancel()
        phaseTimer = nil

        serial?.requestClose()
        serial?.disconnect()
        control?.requestTokenRemove()
        control?.disconnect()

        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.completion?(result)
            self?.completion = nil
        }
    }
}
