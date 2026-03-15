import Foundation
@preconcurrency import Transport

enum PersistentSpeedReader {
    static func read(
        config: ConnectionConfig,
        stageHandler: (@Sendable (String) -> Void)?
    ) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            var reader: PersistentSpeedSession? = PersistentSpeedSession(
                config: config,
                stageHandler: stageHandler
            )
            reader?.start { result in
                defer { reader = nil }
                switch result {
                case .success(let speed):
                    continuation.resume(returning: speed)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private final class PersistentSpeedSession {
    private let config: ConnectionConfig
    private let stageHandler: (@Sendable (String) -> Void)?
    private let queue = DispatchQueue(label: "com.ic705.session.persisted-speed")

    private var control: UDPControl?
    private var serial: UDPSerial?
    private var timeoutWorkItem: DispatchWorkItem?
    private var pollTimer: DispatchSourceTimer?
    private var completion: ((Result<Int, RadioError>) -> Void)?
    private var finished = false

    private var frequencyHz: Int?
    private var modeLabel: String?
    private var cwSpeedWPM: Int?
    private var speedRequested = false

    init(
        config: ConnectionConfig,
        stageHandler: (@Sendable (String) -> Void)?
    ) {
        self.config = config
        self.stageHandler = stageHandler
    }

    func start(completion: @escaping (Result<Int, RadioError>) -> Void) {
        self.completion = completion
        stageHandler?("Starting persistent CW speed reader")

        timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.finish(.failure(.timeout(operation: "readCWSpeed", duration: 20.0)))
        }
        if let timeoutWorkItem {
            queue.asyncAfter(deadline: .now() + 20.0, execute: timeoutWorkItem)
        }

        let control = UDPControl(
            host: config.host,
            userName: config.username,
            password: config.password,
            computerName: "iPhone"
        )
        control.onStage = { [weak self] message in
            self?.stageHandler?("Persistent control: \(message)")
        }
        control.onAuthenticated = { [weak self] in
            self?.queue.async {
                self?.startSerial()
            }
        }
        control.onDisconnect = { [weak self] in
            self?.queue.async {
                guard let self, !self.finished, self.cwSpeedWPM == nil else { return }
                self.finish(.failure(.radioBusy))
            }
        }
        self.control = control
        control.connect()
    }

    private func startSerial() {
        guard let control else { return }
        stageHandler?("Persistent speed opening CI-V port \(control.remoteCIVPort)")

        let serial = UDPSerial(
            host: config.host,
            port: control.remoteCIVPort,
            localPort: control.localCIVPort
        )
        serial.onStage = { [weak self] message in
            self?.stageHandler?("Persistent serial: \(message)")
        }
        serial.onCIVReceived = { [weak self] civData in
            self?.queue.async {
                self?.handleCIV(civData)
            }
        }
        serial.onSerialReady = { [weak self] in
            self?.queue.async {
                self?.stageHandler?("Persistent speed serial ready")
                self?.startPolling()
            }
        }
        self.serial = serial
        serial.connect()
    }

    private func startPolling() {
        pollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.5)
        timer.setEventHandler { [weak self] in
            self?.poll()
        }
        pollTimer = timer
        timer.resume()
    }

    private func poll() {
        guard let serial, !finished else { return }

        if frequencyHz == nil {
            let frame = CIV.buildFrame(command: CIV.Command.readFrequency)
            stageHandler?("Persistent speed polling frequency")
            serial.sendCIV(data: frame, completion: nil)
        }

        if modeLabel == nil {
            let frame = CIV.buildFrame(command: CIV.Command.readMode)
            stageHandler?("Persistent speed polling mode")
            serial.sendCIV(data: frame, completion: nil)
        }

        if !speedRequested, frequencyHz != nil, modeLabel != nil {
            speedRequested = true
            let frame = CIV.buildFrame(command: CIV.Command.setLevel, subCommand: CIV.Command.cwSpeedSub)
            stageHandler?("Persistent speed requesting CW speed")
            serial.sendCIV(data: frame, completion: nil)
        } else if speedRequested, cwSpeedWPM == nil {
            let frame = CIV.buildFrame(command: CIV.Command.setLevel, subCommand: CIV.Command.cwSpeedSub)
            stageHandler?("Persistent speed retrying CW speed")
            serial.sendCIV(data: frame, completion: nil)
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
                stageHandler?("Persistent speed got frequency \(frequencyHz) Hz")
            }
        case CIV.Command.readMode:
            guard civData.count >= 7 else { return }
            modeLabel = CIV.Mode(rawValue: civData[5])?.label
            if let modeLabel {
                stageHandler?("Persistent speed got mode \(modeLabel)")
            }
        case CIV.Command.setLevel:
            guard civData.count >= 8, civData[5] == CIV.Command.cwSpeedSub else { return }
            let high = Int(civData[6])
            let low = civData[7]
            let bcdValue = high * 100 + Int(low >> 4) * 10 + Int(low & 0x0F)
            cwSpeedWPM = Int(round(Double(bcdValue) / 255.0 * Double(CIV.CWSpeed.maxWPM - CIV.CWSpeed.minWPM))) + CIV.CWSpeed.minWPM
            if let cwSpeedWPM {
                stageHandler?("Persistent speed got \(cwSpeedWPM) WPM")
                finish(.success(cwSpeedWPM))
            }
        default:
            break
        }
    }

    private func finish(_ result: Result<Int, RadioError>) {
        guard !finished else { return }
        finished = true

        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        pollTimer?.cancel()
        pollTimer = nil

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
