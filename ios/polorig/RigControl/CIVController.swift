import Foundation
import Observation
import os

private let logger = Logger(subsystem: "com.ic705cwlogger", category: "CIVController")

/// Builds CI-V commands and sends them through the UDP serial layer.
/// Also handles CI-V responses for frequency/mode polling.
@Observable
public final class CIVController {
    private weak var serial: UDPSerial?

    /// Last sent callsign log entries
    public var sentCallsigns: [SentEntry] = []

    /// Current CW speed in WPM
    public var cwSpeed: Int = 20

    // MARK: - Rig State (from CI-V responses)

    /// Current operating frequency in Hz
    public var frequencyHz: Int = 0

    /// Formatted frequency display string
    public var frequencyDisplay: String { frequencyHz > 0 ? CIV.Frequency.formatMHz(frequencyHz) : "---" }

    /// Current operating mode
    public var operatingMode: CIV.Mode? = nil

    // MARK: - QSO Defaults (persisted)

    public var qsoMode: String {
        get { UserDefaults.standard.string(forKey: "qsoMode") ?? "CW" }
        set { UserDefaults.standard.set(newValue, forKey: "qsoMode") }
    }

    public var qsoPowerWatts: Int {
        get {
            let val = UserDefaults.standard.integer(forKey: "qsoPower")
            return val == 0 ? 100 : val
        }
        set { UserDefaults.standard.set(newValue, forKey: "qsoPower") }
    }

    // MARK: - Frequency Polling

    private var pollingTimer: DispatchSourceTimer?

    public struct SentEntry: Identifiable {
        public let id = UUID()
        public let callsign: String
        public let timestamp: Date
        public var status: Status = .sending

        public enum Status {
            case sending, sent, failed
        }
    }

    public init() {}

    public func attach(serial: UDPSerial) {
        self.serial = serial
    }

    // MARK: - Frequency/Mode Requests

    /// Request current frequency from radio (CI-V 0x03)
    public func requestFrequency() {
        let frame = CIV.buildFrame(command: CIV.Command.readFrequency)
        serial?.sendCIV(data: frame, completion: nil)
    }

    /// Request current mode from radio (CI-V 0x04)
    public func requestMode() {
        let frame = CIV.buildFrame(command: CIV.Command.readMode)
        serial?.sendCIV(data: frame, completion: nil)
    }

    /// Request current CW speed from radio (CI-V 0x14 sub 0x0C)
    public func requestCWSpeed() {
        let frame = CIV.buildFrame(command: CIV.Command.setLevel, subCommand: CIV.Command.cwSpeedSub)
        serial?.sendCIV(data: frame, completion: nil)
    }

    /// Start polling frequency at the given interval (default 1 second)
    public func startFrequencyPolling(interval: TimeInterval = 1.0) {
        stopFrequencyPolling()

        // Also request mode and CW speed once at start
        requestMode()
        requestCWSpeed()

        let timer = DispatchSource.makeTimerSource()
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.requestFrequency()
        }
        timer.resume()
        pollingTimer = timer
    }

    /// Stop frequency polling
    public func stopFrequencyPolling() {
        pollingTimer?.cancel()
        pollingTimer = nil
    }

    // MARK: - CI-V Response Handling

    /// Handle incoming CI-V data from the radio.
    /// Called from the serial port's onCIVReceived callback.
    public func handleCIVData(_ civData: Data) {
        // Minimum frame: FE FE dst src cmd data... FD
        guard civData.count >= 6 else { return }
        guard civData[0] == 0xFE, civData[1] == 0xFE else { return }
        guard civData[civData.count - 1] == 0xFD else { return }

        let command = civData[4]
        // Payload is bytes 5..<(count-1)
        let payloadStart = 5
        let payloadEnd = civData.count - 1

        switch command {
        case CIV.Command.readFrequency:
            // Response to 0x03: 5 BCD bytes at positions 5-9
            guard payloadEnd - payloadStart >= 5 else { return }
            let freqBytes = Array(civData[payloadStart..<payloadStart + 5])
            if let hz = CIV.Frequency.parseHz(from: freqBytes) {
                DispatchQueue.main.async { [weak self] in
                    self?.frequencyHz = hz
                }
            }

        case CIV.Command.readMode:
            // Response to 0x04: mode byte at position 5
            guard payloadEnd > payloadStart else { return }
            let modeByte = civData[payloadStart]
            let mode = CIV.Mode(rawValue: modeByte)
            DispatchQueue.main.async { [weak self] in
                self?.operatingMode = mode
            }

        case CIV.Command.setFrequency:
            // Unsolicited frequency change from VFO knob (0x05 echo)
            guard payloadEnd - payloadStart >= 5 else { return }
            let freqBytes = Array(civData[payloadStart..<payloadStart + 5])
            if let hz = CIV.Frequency.parseHz(from: freqBytes) {
                DispatchQueue.main.async { [weak self] in
                    self?.frequencyHz = hz
                }
            }

        case CIV.Command.setLevel:
            // Response to 0x14: sub-command byte + BCD value
            guard payloadEnd - payloadStart >= 3 else { return }
            let sub = civData[payloadStart]
            if sub == CIV.Command.cwSpeedSub {
                // BCD-encoded 0-255 in 2 bytes (high byte + low BCD byte)
                let high = Int(civData[payloadStart + 1])
                let low = civData[payloadStart + 2]
                let bcdValue = high * 100 + Int(low >> 4) * 10 + Int(low & 0x0F)
                let wpm = Int(round(Double(bcdValue) / 255.0 * Double(CIV.CWSpeed.maxWPM - CIV.CWSpeed.minWPM))) + CIV.CWSpeed.minWPM
                DispatchQueue.main.async { [weak self] in
                    self?.cwSpeed = wpm
                }
            }

        default:
            logger.debug("Unhandled CI-V command: 0x\(String(format: "%02X", command))")
        }
    }

    // MARK: - CW Commands

    /// Send a callsign as CW. Appends "?" automatically.
    /// The text is sent as ASCII bytes in a CI-V 0x17 command.
    /// Max 30 characters per transmission.
    public func sendCW(callsign: String) {
        let text = callsign.uppercased() + "?"
        guard !text.isEmpty, text.count <= 30 else { return }

        let asciiBytes = Array(text.utf8).map { UInt8($0) }
        let frame = CIV.buildFrame(command: CIV.Command.sendCW, data: asciiBytes)

        let entry = SentEntry(callsign: callsign.uppercased(), timestamp: Date())
        sentCallsigns.insert(entry, at: 0)

        serial?.sendCIV(data: frame) { [weak self] success in
            guard let self else { return }
            if let index = self.sentCallsigns.firstIndex(where: { $0.id == entry.id }) {
                self.sentCallsigns[index].status = success ? .sent : .failed
            }
        }
    }

    /// Send raw CW text without appending "?"
    public func sendRawCW(text: String, completion: ((Bool) -> Void)? = nil) {
        logger.debug("sendRawCW: ENTER text=\"\(text)\"")
        DebugTrace.write("CIVController", "sendRawCW enter text=\(text)")

        let upper = text.uppercased()
        guard !upper.isEmpty, upper.count <= 30 else {
            logger.warning("sendRawCW: Invalid text (empty or >30 chars)")
            DebugTrace.write("CIVController", "sendRawCW invalid text")
            completion?(false)
            return
        }

        stopFrequencyPolling()
        serial?.flushQueue()

        let asciiBytes = Array(upper.utf8).map { UInt8($0) }
        logger.debug("sendRawCW: ASCII bytes: \(asciiBytes)")
        let frame = CIV.buildFrame(command: CIV.Command.sendCW, data: asciiBytes)
        let frameHex = frame.map { String(format: "%02X", $0) }.joined(separator: " ")
        logger.debug("sendRawCW: Built CI-V frame: [\(frameHex)]")
        DebugTrace.write("CIVController", "sendRawCW frame=[\(frameHex)]")
        logger.debug("sendRawCW: Frame analysis: preamble=\(String(format: "%02X", frame[0])) \(String(format: "%02X", frame[1])), radioAddr=\(String(format: "%02X", frame[2])), ctrlAddr=\(String(format: "%02X", frame[3])), cmd=\(String(format: "%02X", frame[4])), dataLen=\(frame.count-6), terminator=\(String(format: "%02X", frame[frame.count-1]))")
        let resumeDelay = max(MorseTiming.estimateDuration(upper, wpm: cwSpeed) * 1.15, 0.8)
        logger.debug("sendRawCW: Scheduling polling resume after \(resumeDelay, privacy: .public)s for \"\(upper)\"")
        DebugTrace.write("CIVController", "sendRawCW resumeDelay=\(resumeDelay)")

        serial?.sendCIV(data: frame, expectsReply: false) { [weak self] success in
            logger.debug("sendRawCW: sendCIV completion called with success=\(success)")
            NSLog("[CIVController] sendCIV completion: success=%d", success)
            DebugTrace.write("CIVController", "sendRawCW completion success=\(success)")
            DispatchQueue.main.asyncAfter(deadline: .now() + resumeDelay) {
                DebugTrace.write("CIVController", "sendRawCW resuming background traffic + polling")
                self?.serial?.resumeDeferredBackgroundTraffic()
                self?.startFrequencyPolling()
            }
            logger.debug("sendRawCW: Calling completion with \(success)")
            completion?(success)
        }
        logger.debug("sendRawCW: EXIT (sendCIV queued)")
    }

    /// Stop CW transmission in progress
    public func stopCW() {
        stopFrequencyPolling()
        serial?.flushQueue()
        let frame = CIV.buildFrame(command: CIV.Command.sendCW, data: [0xFF])
        serial?.sendCIV(data: frame) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.startFrequencyPolling()
            }
        }
    }

    /// Set CW keying speed in WPM (6-48)
    public func setCWSpeed(wpm: Int) {
        let clamped = min(max(wpm, CIV.CWSpeed.minWPM), CIV.CWSpeed.maxWPM)
        cwSpeed = clamped
        let (high, low) = CIV.CWSpeed.wpmToValue(clamped)
        let frame = CIV.buildFrame(
            command: CIV.Command.setLevel,
            subCommand: CIV.Command.cwSpeedSub,
            data: [high, low]
        )
        serial?.sendCIV(data: frame, completion: nil)
    }

    /// Reset rig state on disconnect
    public func resetState() {
        frequencyHz = 0
        operatingMode = nil
    }
}
