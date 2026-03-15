import Foundation

/// CI-V protocol constants for Icom IC-705
public enum CIV {
    /// IC-705 default CI-V address
    public static let radioAddress: UInt8 = 0xA4

    /// Controller (this app) CI-V address
    public static let controllerAddress: UInt8 = 0xE0

    /// Frame preamble byte (two of these start every CI-V frame)
    public static let preamble: UInt8 = 0xFE

    /// Frame terminator
    public static let terminator: UInt8 = 0xFD

    /// ACK response from radio
    public static let ack: UInt8 = 0xFB

    /// NAK response from radio
    public static let nak: UInt8 = 0xFA

    /// CI-V command codes
    public enum Command {
        /// Read operating frequency (0x03). Response: 5 BCD bytes (LSB first).
        public static let readFrequency: UInt8 = 0x03

        /// Read operating mode (0x04). Response: mode byte + filter byte.
        public static let readMode: UInt8 = 0x04

        /// Set operating frequency (0x05). Payload: 5 BCD bytes (LSB first).
        public static let setFrequency: UInt8 = 0x05

        /// Set operating mode (0x06). Payload: mode byte + filter byte.
        public static let setMode: UInt8 = 0x06

        /// Set/read levels (0x14). Sub-command 0x0C = CW keying speed.
        public static let setLevel: UInt8 = 0x14

        /// Function on/off (0x16). Sub-command 0x47 = break-in mode.
        public static let function: UInt8 = 0x16

        /// Send CW message (0x17). Payload is ASCII text, max 30 chars.
        /// Send 0xFF as payload to stop CW.
        public static let sendCW: UInt8 = 0x17

        /// Sub-command for CW speed under setLevel
        public static let cwSpeedSub: UInt8 = 0x0C

        /// Sub-command for CW pitch under setLevel
        public static let cwPitchSub: UInt8 = 0x09

        /// Sub-command for RF power under setLevel
        public static let rfPowerSub: UInt8 = 0x0A

        /// Sub-command for break-in mode under function
        public static let breakInSub: UInt8 = 0x47
    }

    /// Operating mode values returned by CI-V 0x04
    public enum Mode: UInt8, CaseIterable {
        case lsb  = 0x00
        case usb  = 0x01
        case am   = 0x02
        case cw   = 0x03
        case rtty = 0x04
        case fm   = 0x05
        case cwR  = 0x07
        case rttyR = 0x08

        public var label: String {
            switch self {
            case .lsb:   return "LSB"
            case .usb:   return "USB"
            case .am:    return "AM"
            case .cw:    return "CW"
            case .rtty:  return "RTTY"
            case .fm:    return "FM"
            case .cwR:   return "CW-R"
            case .rttyR: return "RTTY-R"
            }
        }

        /// Default RST report for this mode
        public var defaultRST: String {
            switch self {
            case .cw, .cwR: return "599"
            case .lsb, .usb: return "59"
            case .am, .fm: return "59"
            case .rtty, .rttyR: return "599"
            }
        }
    }

    /// Frequency encoding/decoding for CI-V BCD format
    public enum Frequency {
        /// Decode 5 BCD bytes (LSB first) to Hz.
        /// Each byte contains two BCD digits. Byte order: 1Hz/10Hz, 100Hz/1kHz, 10kHz/100kHz, 1MHz/10MHz, 100MHz/1GHz
        public static func parseHz(from bytes: [UInt8]) -> Int? {
            guard bytes.count >= 5 else { return nil }
            var hz = 0
            var multiplier = 1
            for byte in bytes {
                let lowNibble = Int(byte & 0x0F)
                let highNibble = Int((byte >> 4) & 0x0F)
                guard lowNibble <= 9, highNibble <= 9 else { return nil }
                hz += lowNibble * multiplier
                multiplier *= 10
                hz += highNibble * multiplier
                multiplier *= 10
            }
            return hz
        }

        /// Format Hz as a readable frequency string (e.g., "14.060.00 MHz")
        public static func formatMHz(_ hz: Int) -> String {
            let mhz = Double(hz) / 1_000_000.0
            if hz >= 1_000_000_000 {
                return String(format: "%.3f GHz", mhz / 1000.0)
            } else if hz >= 1_000_000 {
                return String(format: "%.3f MHz", mhz)
            } else {
                return String(format: "%.3f kHz", Double(hz) / 1000.0)
            }
        }

        /// Format Hz as a short kHz string for CW macros (e.g., "14060")
        public static func formatKHz(_ hz: Int) -> String {
            return "\(hz / 1000)"
        }

        /// Encode Hz to 5 BCD bytes (LSB first) for CI-V set-frequency command
        public static func toBytes(_ hz: Int) -> [UInt8] {
            var remaining = hz
            var bytes: [UInt8] = []
            for _ in 0..<5 {
                let lowDigit = remaining % 10
                remaining /= 10
                let highDigit = remaining % 10
                remaining /= 10
                bytes.append(UInt8((highDigit << 4) | lowDigit))
            }
            return bytes
        }
    }

    /// CW speed range
    public enum CWSpeed {
        public static let minWPM = 6
        public static let maxWPM = 48

        /// Convert WPM to the 0-255 BCD-encoded value the radio expects.
        /// The IC-705 maps 6 WPM → 0x0000 and 48 WPM → 0x0255 (BCD).
        /// The value is linearly interpolated and encoded as 4-digit BCD in 2 bytes.
        public static func wpmToValue(_ wpm: Int) -> (UInt8, UInt8) {
            let clamped = min(max(wpm, minWPM), maxWPM)
            // Linear mapping: 6 WPM = 0, 48 WPM = 255
            let raw = Int(round(Double(clamped - minWPM) / Double(maxWPM - minWPM) * 255.0))
            // Encode as 4-digit BCD in 2 bytes: e.g., 128 → 0x01, 0x28
            let high = UInt8(raw / 100)
            let lowTens = UInt8((raw % 100) / 10)
            let lowOnes = UInt8(raw % 10)
            return (high, (lowTens << 4) | lowOnes)
        }
    }

    /// Build a complete CI-V frame: FE FE <to> <from> <cmd> [data...] FD
    public static func buildFrame(command: UInt8, subCommand: UInt8? = nil, data: [UInt8] = []) -> Data {
        var frame: [UInt8] = [preamble, preamble, radioAddress, controllerAddress, command]
        if let sub = subCommand {
            frame.append(sub)
        }
        frame.append(contentsOf: data)
        frame.append(terminator)
        return Data(frame)
    }
}
