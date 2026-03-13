import Foundation
import os

private let logger = Logger(subsystem: "com.ac0vw.polorig", category: "IC705RigControl")

/// React Native Native Module bridging the IC-705 rig control stack.
/// Wraps UDPControl, UDPSerial, CIVController, CWKeyer, and CWSidetone,
/// exposing them as promise-based methods and event emitters to JavaScript.
@objc(IC705RigControl)
class IC705RigControl: RCTEventEmitter {
    /// Shared instance for AppDelegate cleanup on termination.
    static weak var activeInstance: IC705RigControl?

    private var control: UDPControl?
    private var serial: UDPSerial?
    private let civController = CIVController()
    private let keyer = CWKeyer()
    private let sidetone = CWSidetone()
    private var isConnected = false
    private var hasListeners = false
    private var connectTimeoutWorkItem: DispatchWorkItem?

    // Track previous values to emit only on change
    private var lastFrequencyHz: Int = 0
    private var lastMode: String? = nil
    private var lastCWSpeed: Int = 0
    private var lastIsSending = false

    override init() {
        super.init()
        IC705RigControl.activeInstance = self
    }

    override static func requiresMainQueueSetup() -> Bool { true }

    /// Synchronous disconnect for use during app termination.
    func disconnectSync() {
        guard isConnected else { return }
        civController.stopFrequencyPolling()
        keyer.cancelSend()
        serial?.disconnect()
        control?.disconnect()
        isConnected = false
        control = nil
        serial = nil
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

    // MARK: - Connect

    @objc func connect(_ host: String, username: String, password: String,
                       resolver resolve: @escaping RCTPromiseResolveBlock,
                       rejecter reject: @escaping RCTPromiseRejectBlock) {
        guard !isConnected else {
            reject("ALREADY_CONNECTED", "Already connected to radio", nil)
            return
        }

        logger.info("Connecting to \(host)...")
        emitConnectionState("connecting", detail: "Opening control connection to \(host)")

        connectTimeoutWorkItem?.cancel()

        let ctrl = UDPControl(host: host, port: 50001, userName: username, password: password)
        var promiseSettled = false
        ctrl.onStage = { [weak self] detail in
            self?.emitConnectionState("connecting", detail: detail)
        }

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            guard let self, !promiseSettled else { return }
            promiseSettled = true
            self.serial?.disconnect()
            self.control?.disconnect()
            self.handleDisconnect()
            reject("CONNECTION_TIMEOUT", "Could not connect to radio within 12 seconds", nil)
        }
        connectTimeoutWorkItem = timeoutWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeoutWorkItem)

        ctrl.onAuthenticated = { [weak self] in
            guard let self else { return }

            logger.info("Authenticated with \(ctrl.radioName)")
            self.emitEvent("onRadioNameChanged", body: ["name": ctrl.radioName])
            self.emitConnectionState("connecting", detail: "Authenticated with \(ctrl.radioName); opening CI-V stream")

            let ser = UDPSerial(host: host, port: ctrl.remoteCIVPort, localPort: ctrl.localCIVPort)
            self.serial = ser
            ser.onStage = { [weak self] detail in
                self?.emitConnectionState("connecting", detail: detail)
            }

            // Wire CIV controller to serial port
            self.civController.attach(serial: ser)
            ser.onCIVReceived = { [weak self] data in
                self?.civController.handleCIVData(data)
            }

            // Wire keyer callbacks
            self.keyer.onSendCW = { [weak self] text, completion in
                logger.debug("keyer.onSendCW: Sending \"\(text)\"")
                self?.civController.sendRawCW(text: text) { success in
                    logger.debug("keyer.onSendCW: Got result success=\(success) for \"\(text)\"")
                    self?.emitEvent("onCWResult", body: [
                        "text": text,
                        "success": success,
                        "source": "keyer"
                    ])
                    completion(success)
                }
            }
            self.keyer.onSetSpeed = { [weak self] wpm in
                self?.civController.setCWSpeed(wpm: wpm)
            }
            self.keyer.onChunkSent = { [weak self] chunk, wpm in
                self?.sidetone.playText(chunk, wpm: wpm)
            }
            self.keyer.onSendingDidStart = { [weak self] in
                self?.emitSendingState(true)
            }
            self.keyer.onSendingDidEnd = { [weak self] in
                self?.emitSendingState(false)
            }

            ser.onSerialReady = { [weak self] in
                guard let self, !promiseSettled else { return }
                promiseSettled = true
                self.connectTimeoutWorkItem?.cancel()
                self.connectTimeoutWorkItem = nil
                self.civController.startFrequencyPolling()
                self.startStatePolling()
                self.isConnected = true
                self.emitConnectionState("connected", detail: "Connected to \(ctrl.radioName)")
                resolve(["radioName": ctrl.radioName])
            }
            ser.connect()
        }

        ctrl.onDisconnect = { [weak self] in
            guard let self else { return }
            if !promiseSettled {
                promiseSettled = true
                self.connectTimeoutWorkItem?.cancel()
                self.connectTimeoutWorkItem = nil
                self.emitConnectionState("disconnected", detail: "Control connection closed before setup completed")
                reject("CONNECTION_TIMEOUT", "Could not connect to radio — timed out or unreachable", nil)
            }
            self.handleDisconnect()
        }

        self.control = ctrl
        ctrl.connect()
    }

    // MARK: - Disconnect

    @objc func disconnect(_ resolve: @escaping RCTPromiseResolveBlock,
                          rejecter reject: @escaping RCTPromiseRejectBlock) {
        guard isConnected else {
            resolve(nil)
            return
        }

        civController.stopFrequencyPolling()
        keyer.cancelSend()
        connectTimeoutWorkItem?.cancel()
        connectTimeoutWorkItem = nil
        serial?.disconnect()
        control?.disconnect()
        handleDisconnect()
        resolve(nil)
    }

    private func handleDisconnect() {
        connectTimeoutWorkItem?.cancel()
        connectTimeoutWorkItem = nil
        isConnected = false
        civController.resetState()
        lastFrequencyHz = 0
        lastMode = nil
        lastCWSpeed = 0
        lastIsSending = false
        control = nil
        serial = nil
        emitConnectionState("disconnected")
    }

    // MARK: - CW Sending

    @objc func sendCW(_ text: String,
                      resolver resolve: @escaping RCTPromiseResolveBlock,
                      rejecter reject: @escaping RCTPromiseRejectBlock) {
        logger.debug("sendCW: ENTER text=\"\(text)\"")
        guard isConnected else {
            logger.warning("sendCW: Rejecting - not connected")
            reject("NOT_CONNECTED", "Not connected to radio", nil)
            return
        }

        civController.sendRawCW(text: text) { [weak self] success in
            logger.debug("sendCW: sendRawCW completion success=\(success)")
            self?.emitEvent("onCWResult", body: [
                "text": text,
                "success": success,
                "source": "direct"
            ])
            if success {
                resolve(nil)
            } else {
                reject("CW_SEND_FAILED", "Radio did not accept CW command", nil)
            }
        }
    }

    @objc func sendTemplatedCW(_ templateStr: String, variables: NSDictionary,
                                resolver resolve: @escaping RCTPromiseResolveBlock,
                                rejecter reject: @escaping RCTPromiseRejectBlock) {
        logger.debug("sendTemplatedCW: ENTER template=\"\(templateStr)\" variables=\(variables)")
        guard isConnected else {
            logger.warning("sendTemplatedCW: Rejecting - not connected")
            reject("NOT_CONNECTED", "Not connected to radio", nil)
            return
        }

        // Convert NSDictionary to [String: String]
        var vars: [String: String] = [:]
        for (key, value) in variables {
            if let k = key as? String, let v = value as? String {
                vars[k] = v
            }
        }
        logger.debug("sendTemplatedCW: Parsed vars: \(vars)")

        let context = KeyerContext(
            callsign: vars["callsign"] ?? "",
            myCallsign: vars["mycall"] ?? "",
            frequencyHz: civController.frequencyHz,
            operatingMode: civController.operatingMode,
            cwSpeed: civController.cwSpeed
        )
        logger.debug("sendTemplatedCW: Context - callsign=\(context.callsign), myCallsign=\(context.myCallsign), freq=\(context.frequencyHz), speed=\(context.cwSpeed)")

        keyer.sendInterpolatedTemplate(templateStr, variables: vars, context: context)
        logger.debug("sendTemplatedCW: EXIT (template queued)")
        resolve(nil)
    }

    @objc func setCWSpeed(_ wpm: NSNumber,
                          resolver resolve: @escaping RCTPromiseResolveBlock,
                          rejecter reject: @escaping RCTPromiseRejectBlock) {
        guard isConnected else {
            reject("NOT_CONNECTED", "Not connected to radio", nil)
            return
        }

        civController.setCWSpeed(wpm: wpm.intValue)
        resolve(nil)
    }

    @objc func cancelCW() {
        keyer.cancelSend()
        civController.stopCW()
    }

    // MARK: - Status

    @objc func getStatus(_ resolve: @escaping RCTPromiseResolveBlock,
                         rejecter reject: @escaping RCTPromiseRejectBlock) {
        resolve([
            "isConnected": isConnected,
            "frequencyHz": civController.frequencyHz,
            "mode": civController.operatingMode?.label ?? NSNull(),
            "cwSpeed": civController.cwSpeed,
            "isSending": keyer.isSending,
            "radioName": control?.radioName ?? NSNull(),
        ])
    }

    // MARK: - State Polling (CI-V values → JS events)

    private var stateTimer: DispatchSourceTimer?

    private func startStatePolling() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            self?.checkAndEmitStateChanges()
        }
        timer.resume()
        stateTimer = timer
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

    // MARK: - Event Helpers

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
}
