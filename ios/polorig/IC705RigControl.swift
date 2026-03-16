import Foundation
import os
import SessionManager

private let logger = Logger(subsystem: "com.ac0vw.polorig", category: "IC705RigControl")
private let traceLogger = Logger(subsystem: "com.ac0vw.polorig", category: "IC705Trace")

@objc(IC705RigControl)
class IC705RigControl: RCTEventEmitter {
    static weak var activeInstance: IC705RigControl?

    private let civController = CIVController()
    private let keyer = CWKeyer()
    private let sidetone = CWSidetone()

    private var radioSession: PersistentRadioSession?
    private var radioConfig: ConnectionConfig?
    private var isConnected = false
    private var hasListeners = false
    private var currentRadioName: String?
    private var currentHost = ""
    private var currentUsername = ""
    private var currentPassword = ""

    private var connectTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var pollTimer: DispatchSourceTimer?
    private var pollGeneration: Int = 0
    private var pollCounter: Int = 0

    private let traceSessionId = UUID().uuidString
    private var traceSequence: UInt64 = 0

    private var lastFrequencyHz: Int = 0
    private var lastMode: String? = nil
    private var lastCWSpeed: Int = 0
    private var lastIsSending = false

    override init() {
        super.init()
        IC705RigControl.activeInstance = self
        DebugTrace.clear()
        DebugTrace.write("IC705RigControl", "module init session=\(traceSessionId)")
        logTrace("native.module.init", detail: "session=\(traceSessionId)")
        configureKeyerCallbacks()
    }

    override static func requiresMainQueueSetup() -> Bool { true }

    func disconnectSync() {
        stopStatePolling()
        keyer.cancelSend()

        let semaphore = DispatchSemaphore(value: 0)
        let session = radioSession
        connectTask?.cancel()
        connectTask = nil

        if let session {
            Task {
                await session.disconnect()
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 2.5)
        }

        cleanupAfterDisconnect()
    }

    override func supportedEvents() -> [String]! {
        [
            "onConnectionStateChanged",
            "onFrequencyChanged",
            "onModeChanged",
            "onCWSpeedChanged",
            "onSendingStateChanged",
            "onRadioNameChanged",
            "onCWResult",
        ]
    }

    override func startObserving() {
        hasListeners = true
    }

    override func stopObserving() {
        hasListeners = false
    }

    @objc func connect(_ host: String, username: String, password: String,
                       resolver resolve: @escaping RCTPromiseResolveBlock,
                       rejecter reject: @escaping RCTPromiseRejectBlock) {
        guard !isConnected, radioSession == nil else {
            reject("ALREADY_CONNECTED", "Already connected to radio", nil)
            return
        }

        currentHost = host
        currentUsername = username
        currentPassword = password

        let config = ConnectionConfig(
            host: host,
            username: username,
            password: password,
            computerName: "PoloRig"
        )
        radioConfig = config

        let session = PersistentRadioSession(config: config)
        session.stageHandler = { [weak self] detail in
            DispatchQueue.main.async {
                guard let self else { return }
                let state = self.isConnected ? "connected" : "connecting"
                self.emitConnectionState(state, detail: detail)
            }
        }
        radioSession = session

        emitConnectionState("connecting", detail: "Opening unified persistent session to \(host)")
        logger.info("Connecting to \(host)")

        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await session.connect()
                try Task.checkCancellation()

                await MainActor.run {
                    self.connectTask = nil
                    self.isConnected = true
                    self.currentRadioName = result.radioName
                    self.emitEvent("onRadioNameChanged", body: ["name": result.radioName])
                    self.emitConnectionState("connected", detail: "Connected to \(result.radioName)")
                }

                await self.refreshCachedState(includeSpeed: true, emitChanges: true, allowBusyFailure: true)
                await MainActor.run {
                    self.startStatePolling()
                    resolve(["radioName": result.radioName])
                }
            } catch {
                await MainActor.run {
                    self.connectTask = nil
                    self.cleanupAfterDisconnect()
                    self.emitConnectionState("disconnected", detail: self.errorDescription(error))
                    reject("CONNECTION_FAILED", self.errorDescription(error), error as NSError)
                }
            }
        }
    }

    @objc func disconnect(_ resolve: @escaping RCTPromiseResolveBlock,
                          rejecter reject: @escaping RCTPromiseRejectBlock) {
        disconnectSync()
        resolve(nil)
    }

    @objc func sendCW(_ text: String,
                      resolver resolve: @escaping RCTPromiseResolveBlock,
                      rejecter reject: @escaping RCTPromiseRejectBlock) {
        let trimmed = text.uppercased()
        guard !trimmed.isEmpty, trimmed.count <= 30 else {
            reject("CW_INVALID", "CW text must be 1-30 characters", nil)
            return
        }
        guard let session = radioSession, isConnected else {
            reject("NOT_CONNECTED", "Not connected to radio", nil)
            return
        }

        logger.debug("sendCW text=\"\(trimmed)\"")
        DebugTrace.write("IC705RigControl", "sendCW persistent text=\(trimmed)")

        Task { [weak self] in
            guard let self else { return }
            do {
                let success = try await session.sendCW(trimmed)
                await MainActor.run {
                    self.emitEvent("onCWResult", body: [
                        "text": trimmed,
                        "success": success,
                        "source": "persistent"
                    ])
                    if success {
                        resolve(nil)
                    } else {
                        reject("CW_SEND_FAILED", "Radio did not accept CW command", nil)
                    }
                }
            } catch {
                await MainActor.run {
                    self.emitEvent("onCWResult", body: [
                        "text": trimmed,
                        "success": false,
                        "source": "persistent"
                    ])
                    reject("CW_SEND_FAILED", self.errorDescription(error), error as NSError)
                }
            }
        }
    }

    @objc func logUIEvent(_ name: String, detail: String,
                          resolver resolve: @escaping RCTPromiseResolveBlock,
                          rejecter reject: @escaping RCTPromiseRejectBlock) {
        logTrace(name, detail: detail)
        resolve(nil)
    }

    @objc func sendTemplatedCW(_ templateStr: String, variables: NSDictionary,
                               resolver resolve: @escaping RCTPromiseResolveBlock,
                               rejecter reject: @escaping RCTPromiseRejectBlock) {
        var vars: [String: String] = [:]
        for (key, value) in variables {
            if let k = key as? String, let v = value as? String {
                vars[k] = v
            }
        }

        let context = KeyerContext(
            callsign: vars["callsign"] ?? "",
            myCallsign: vars["mycall"] ?? "",
            frequencyHz: civController.frequencyHz,
            operatingMode: civController.operatingMode,
            cwSpeed: civController.cwSpeed
        )
        let interpolated = CWTemplateEngine.interpolate(templateStr, variables: vars).uppercased()

        guard !interpolated.isEmpty, interpolated.count <= 30 else {
            reject("CW_TEMPLATE_INVALID", "Interpolated CW text must be 1-30 characters", nil)
            return
        }

        logger.debug("sendTemplatedCW text=\"\(interpolated)\"")
        DebugTrace.write("IC705RigControl", "sendTemplatedCW text=\(interpolated)")
        _ = context

        sendCW(interpolated, resolver: resolve, rejecter: reject)
    }

    @objc func setCWSpeed(_ wpm: NSNumber,
                          resolver resolve: @escaping RCTPromiseResolveBlock,
                          rejecter reject: @escaping RCTPromiseRejectBlock) {
        guard let session = radioSession, isConnected else {
            reject("NOT_CONNECTED", "Not connected to radio", nil)
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await session.setCWSpeed(wpm.intValue)
                await MainActor.run {
                    self.civController.cwSpeed = min(max(wpm.intValue, CIV.CWSpeed.minWPM), CIV.CWSpeed.maxWPM)
                    self.checkAndEmitStateChanges()
                    resolve(nil)
                }
            } catch {
                await MainActor.run {
                    reject("CW_SPEED_FAILED", self.errorDescription(error), error as NSError)
                }
            }
        }
    }

    @objc func cancelCW() {
        keyer.cancelSend()
        guard let session = radioSession, isConnected else { return }
        Task {
            try? await session.stopCW()
        }
    }

    @objc func getStatus(_ resolve: @escaping RCTPromiseResolveBlock,
                         rejecter reject: @escaping RCTPromiseRejectBlock) {
        resolve(statusPayload())
    }

    @objc func refreshStatus(_ resolve: @escaping RCTPromiseResolveBlock,
                             rejecter reject: @escaping RCTPromiseRejectBlock) {
        guard radioSession != nil, isConnected else {
            resolve(statusPayload())
            return
        }

        Task { [weak self] in
            guard let self else { return }
            await self.refreshCachedState(includeSpeed: true, emitChanges: true, allowBusyFailure: true)
            await MainActor.run {
                resolve(self.statusPayload())
            }
        }
    }

    private func configureKeyerCallbacks() {
        keyer.onSendCW = { [weak self] text, completion in
            guard let self, let session = self.radioSession, self.isConnected else {
                completion(false)
                return
            }
            Task {
                let success = (try? await session.sendCW(text.uppercased())) ?? false
                await MainActor.run {
                    self.emitEvent("onCWResult", body: [
                        "text": text.uppercased(),
                        "success": success,
                        "source": "keyer"
                    ])
                    completion(success)
                }
            }
        }

        keyer.onSetSpeed = { [weak self] wpm in
            guard let self, let session = self.radioSession, self.isConnected else { return }
            Task {
                try? await session.setCWSpeed(wpm)
                await MainActor.run {
                    self.civController.cwSpeed = wpm
                    self.checkAndEmitStateChanges()
                }
            }
        }

        keyer.onChunkSent = { [weak self] chunk, wpm in
            self?.sidetone.playText(chunk, wpm: wpm)
        }
        keyer.onSendingDidStart = { [weak self] in
            self?.emitSendingState(true)
        }
        keyer.onSendingDidEnd = { [weak self] in
            self?.emitSendingState(false)
        }
    }

    private func startStatePolling() {
        stopStatePolling()
        pollGeneration &+= 1
        let generation = pollGeneration

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self, self.isConnected else { return }
            guard self.pollTask == nil else { return }

            self.pollCounter += 1
            let includeSpeed = self.pollCounter % 4 == 0
            self.pollTask = Task { [weak self] in
                guard let self else { return }
                await self.refreshCachedState(includeSpeed: includeSpeed, emitChanges: true, allowBusyFailure: true)
                await MainActor.run {
                    self.pollTask = nil
                }
            }
        }
        timer.resume()
        pollTimer = timer
    }

    private func stopStatePolling() {
        pollTimer?.cancel()
        pollTimer = nil
        pollTask?.cancel()
        pollTask = nil
    }

    private func refreshCachedState(includeSpeed: Bool, emitChanges: Bool, allowBusyFailure: Bool) async {
        guard let session = radioSession, isConnected else { return }

        do {
            let status = try await session.queryStatus()
            await MainActor.run {
                self.applyStatus(status)
                if emitChanges {
                    self.checkAndEmitStateChanges()
                }
            }
        } catch {
            if !allowBusyFailure || !isRadioBusy(error) {
                logger.warning("Status refresh failed: \(self.errorDescription(error), privacy: .public)")
            }
        }

        guard includeSpeed else { return }

        do {
            let speed = try await session.queryCWSpeed()
            await MainActor.run {
                self.civController.cwSpeed = speed
                if emitChanges {
                    self.checkAndEmitStateChanges()
                }
            }
        } catch {
            if !allowBusyFailure || !isRadioBusy(error) {
                logger.warning("CW speed refresh failed: \(self.errorDescription(error), privacy: .public)")
            }
        }
    }

    private func applyStatus(_ status: StatusResult) {
        civController.frequencyHz = status.frequencyHz
        civController.operatingMode = CIV.Mode.allCases.first(where: { $0.label == status.mode })
    }

    private func cleanupAfterDisconnect() {
        connectTask?.cancel()
        connectTask = nil
        stopStatePolling()
        isConnected = false
        radioSession = nil
        radioConfig = nil
        currentRadioName = nil
        civController.stopFrequencyPolling()
        lastFrequencyHz = 0
        lastMode = nil
        lastCWSpeed = 0
        lastIsSending = false
        emitConnectionState("disconnected")
    }

    private func statusPayload() -> [String: Any] {
        [
            "isConnected": isConnected,
            "frequencyHz": civController.frequencyHz,
            "mode": civController.operatingMode?.label ?? NSNull(),
            "cwSpeed": civController.cwSpeed,
            "isSending": keyer.isSending,
            "radioName": currentRadioName ?? NSNull(),
        ]
    }

    private func checkAndEmitStateChanges() {
        guard hasListeners else { return }

        let freq = civController.frequencyHz
        if freq != lastFrequencyHz {
            lastFrequencyHz = freq
            emitEvent("onFrequencyChanged", body: [
                "frequencyHz": freq,
                "display": civController.frequencyDisplay,
            ])
        }

        let mode = civController.operatingMode?.label
        if mode != lastMode {
            lastMode = mode
            emitEvent("onModeChanged", body: [
                "mode": mode ?? NSNull(),
            ])
        }

        let speed = civController.cwSpeed
        if speed != lastCWSpeed {
            lastCWSpeed = speed
            emitEvent("onCWSpeedChanged", body: [
                "wpm": speed,
            ])
        }

        let sending = keyer.isSending
        if sending != lastIsSending {
            lastIsSending = sending
            emitSendingState(sending)
        }
    }

    private func emitEvent(_ name: String, body: [String: Any]) {
        guard hasListeners else { return }
        sendEvent(withName: name, body: body)
    }

    private func emitConnectionState(_ state: String, detail: String? = nil) {
        var body: [String: Any] = ["state": state]
        if let detail {
            body["detail"] = detail
        }
        emitEvent("onConnectionStateChanged", body: body)
    }

    private func emitSendingState(_ isSending: Bool) {
        emitEvent("onSendingStateChanged", body: ["isSending": isSending])
    }

    private func logTrace(_ name: String, detail: String? = nil) {
        traceSequence &+= 1
        let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedDetail.isEmpty {
            traceLogger.log("[session=\(self.traceSessionId, privacy: .public) seq=\(self.traceSequence)] \(name, privacy: .public)")
        } else {
            traceLogger.log("[session=\(self.traceSessionId, privacy: .public) seq=\(self.traceSequence)] \(name, privacy: .public) | \(trimmedDetail, privacy: .public)")
        }
    }

    private func errorDescription(_ error: Error) -> String {
        if let radioError = error as? RadioError {
            return radioError.description
        }
        return error.localizedDescription
    }

    private func isRadioBusy(_ error: Error) -> Bool {
        guard let radioError = error as? RadioError else { return false }
        switch radioError {
        case .radioBusy, .operationInProgress:
            return true
        default:
            return false
        }
    }
}
