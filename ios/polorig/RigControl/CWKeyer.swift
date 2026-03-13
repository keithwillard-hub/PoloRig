import Foundation
import os

private let logger = Logger(subsystem: "com.ic705cwlogger", category: "CWKeyer")

/// Context provided to the keyer for macro expansion
public struct KeyerContext {
    public var callsign: String = ""
    public var myCallsign: String = ""
    public var frequencyHz: Int = 0
    public var operatingMode: CIV.Mode? = nil
    public var cwSpeed: Int = 20

    public init(callsign: String = "", myCallsign: String = "", frequencyHz: Int = 0, operatingMode: CIV.Mode? = nil, cwSpeed: Int = 20) {
        self.callsign = callsign
        self.myCallsign = myCallsign
        self.frequencyHz = frequencyHz
        self.operatingMode = operatingMode
        self.cwSpeed = cwSpeed
    }
}

/// Items that can be placed in the send buffer
public enum SendBufferEntry {
    case text(String)
    case speedChange(Int)
    case delay(TimeInterval)
    case serialNumber
}

/// A stored CW memory message with macro placeholders
public struct CWMemory: Codable, Identifiable {
    public let id: UUID
    public var label: String
    public var content: String

    public init(id: UUID = UUID(), label: String, content: String) {
        self.id = id
        self.label = label
        self.content = content
    }
}

/// CW Keyer engine: macro expansion, send buffer management, 30-char chunking, pacing.
///
/// Inspired by K3NG keyer (timing/macros) and wfview cwSender (chunking/pacing).
/// The IC-705 handles Morse encoding internally via CI-V 0x17. This keyer focuses on
/// message composition, macro expansion, and send buffer management.
@Observable
public final class CWKeyer {
    // MARK: - Properties

    /// Queue of items waiting to be sent
    public private(set) var sendBuffer: [SendBufferEntry] = []

    /// Currently transmitting
    public private(set) var isSending = false

    /// Auto-incrementing contest serial number (persisted)
    public var serialNumber: Int {
        get { UserDefaults.standard.integer(forKey: "cwSerialNumber").nonZeroOr(1) }
        set { UserDefaults.standard.set(newValue, forKey: "cwSerialNumber") }
    }

    /// Use cut numbers (T=0, N=9) for shorter Morse
    public var cutNumbersEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "cwCutNumbers") }
        set { UserDefaults.standard.set(newValue, forKey: "cwCutNumbers") }
    }

    /// Operator's own callsign (persisted, used by {MYCALL} macro)
    public var myCallsign: String {
        get { UserDefaults.standard.string(forKey: "myCallsign") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "myCallsign") }
    }

    /// 6 stored memory messages (persisted)
    public var memories: [CWMemory] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "cwMemories"),
                  let decoded = try? JSONDecoder().decode([CWMemory].self, from: data) else {
                return Self.defaultMemories
            }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "cwMemories")
            }
        }
    }

    // MARK: - Callbacks

    /// Called to send raw CW text via CI-V 0x17 (max 30 chars)
    public var onSendCW: ((String, @escaping (Bool) -> Void) -> Void)?

    /// Called to change CW speed
    public var onSetSpeed: ((Int) -> Void)?

    /// Called when a chunk is sent (for sidetone playback)
    public var onChunkSent: ((String, Int) -> Void)?

    /// Called when CW sending starts (first chunk)
    public var onSendingDidStart: (() -> Void)?

    /// Called when CW sending finishes (buffer empty or cancelled)
    public var onSendingDidEnd: (() -> Void)?

    // MARK: - Init

    public init() {}

    // MARK: - Private

    private var processingTimer: DispatchSourceTimer?
    private let processingQueue = DispatchQueue(label: "com.ic705cwlogger.keyer")

    // MARK: - Default Memories

    public static let defaultMemories: [CWMemory] = [
        CWMemory(label: "CQ", content: "CQ CQ CQ DE $mycall $mycall K"),
        CWMemory(label: "Reply", content: "$callsign DE $mycall UR RST $rst $rst K"),
        CWMemory(label: "Serial", content: "NR {SERIAL} {SERIAL}"),
        CWMemory(label: "73", content: "$callsign TU 73 DE $mycall SK"),
        CWMemory(label: "AGN?", content: "$callsign AGN?"),
        CWMemory(label: "QRZ?", content: "QRZ? DE $mycall K"),
    ]

    // MARK: - Macro Expansion

    /// Expand macro placeholders in a template string into send buffer entries
    public func expandMacros(template: String, context: KeyerContext) -> [SendBufferEntry] {
        var entries: [SendBufferEntry] = []
        var remaining = template

        while !remaining.isEmpty {
            if let braceRange = remaining.range(of: "{") {
                // Text before the macro
                let prefix = String(remaining[remaining.startIndex..<braceRange.lowerBound])
                if !prefix.isEmpty {
                    entries.append(.text(prefix))
                }

                // Find closing brace
                let afterBrace = remaining[braceRange.upperBound...]
                if let closeRange = afterBrace.range(of: "}") {
                    let macroContent = String(afterBrace[afterBrace.startIndex..<closeRange.lowerBound])
                    remaining = String(afterBrace[closeRange.upperBound...])

                    // Parse the macro
                    let expanded = expandSingleMacro(macroContent, context: context)
                    entries.append(contentsOf: expanded)
                } else {
                    // No closing brace, treat rest as literal text
                    entries.append(.text(String(remaining[braceRange.lowerBound...])))
                    remaining = ""
                }
            } else {
                // No more macros, rest is literal text
                entries.append(.text(remaining))
                remaining = ""
            }
        }

        return entries
    }

    private func expandSingleMacro(_ macro: String, context: KeyerContext) -> [SendBufferEntry] {
        let upper = macro.uppercased()

        if upper == "CALL" {
            return [.text(context.callsign.uppercased())]
        }
        if upper == "MYCALL" {
            return [.text(context.myCallsign.uppercased())]
        }
        if upper == "SERIAL" {
            return [.serialNumber]
        }
        if upper == "CUT" {
            let formatted = formatSerialNumber(serialNumber, useCutNumbers: true)
            return [.text(formatted)]
        }
        if upper == "RST" {
            let rst = context.operatingMode?.defaultRST ?? "599"
            return [.text(rst)]
        }
        if upper == "FREQ" {
            return [.text(CIV.Frequency.formatKHz(context.frequencyHz))]
        }
        if upper.hasPrefix("SPEED:") {
            let wpmStr = String(upper.dropFirst(6))
            if let wpm = Int(wpmStr) {
                return [.speedChange(wpm)]
            }
        }
        if upper.hasPrefix("DELAY:") {
            let secStr = String(upper.dropFirst(6))
            if let sec = Double(secStr) {
                return [.delay(sec)]
            }
        }

        // Unknown macro — pass through as literal text
        return [.text("{\(macro)}")]
    }

    // MARK: - Serial Number Formatting

    /// Format a serial number, optionally with cut numbers (T=0, N=9)
    public func formatSerialNumber(_ number: Int, useCutNumbers: Bool = false) -> String {
        let formatted = String(format: "%03d", number)
        if !useCutNumbers { return formatted }

        return String(formatted.map { char in
            switch char {
            case "0": return Character("T")
            case "9": return Character("N")
            default: return char
            }
        })
    }

    // MARK: - Send

    /// Expand a template and queue all entries for sending
    public func sendTemplate(_ template: String, context: KeyerContext) {
        let entries = expandMacros(template: template, context: context)
        send(entries: entries, wpm: context.cwSpeed)
    }

    /// Send a templated message with `$variable` interpolation, then `{MACRO}` expansion.
    /// Variables are substituted first, then the result is passed through macro expansion.
    public func sendInterpolatedTemplate(_ template: String, variables: [String: String], context: KeyerContext) {
        let interpolated = CWTemplateEngine.interpolate(template, variables: variables)
        sendTemplate(interpolated, context: context)
    }

    /// Queue entries into the send buffer and start processing
    public func send(entries: [SendBufferEntry], wpm: Int) {
        processingQueue.async { [weak self] in
            guard let self else { return }
            self.sendBuffer.append(contentsOf: entries)
            if !self.isSending {
                DispatchQueue.main.async {
                    self.isSending = true
                    self.onSendingDidStart?()
                }
                self.processNextEntry(wpm: wpm)
            }
        }
    }

    /// Cancel all pending sends
    public func cancelSend() {
        processingQueue.async { [weak self] in
            guard let self else { return }
            self.sendBuffer.removeAll()
            self.processingTimer?.cancel()
            self.processingTimer = nil
            DispatchQueue.main.async {
                self.isSending = false
                self.onSendingDidEnd?()
            }
        }
    }

    // MARK: - Buffer Processing

    private func processNextEntry(wpm: Int) {
        processingQueue.async { [weak self] in
            guard let self, !self.sendBuffer.isEmpty else {
                DispatchQueue.main.async {
                    self?.isSending = false
                    self?.onSendingDidEnd?()
                }
                return
            }

            let entry = self.sendBuffer.removeFirst()
            var currentWpm = wpm

            switch entry {
            case .text(let text):
                self.sendTextInChunks(text, wpm: currentWpm)

            case .speedChange(let newWpm):
                currentWpm = newWpm
                DispatchQueue.main.async { self.onSetSpeed?(newWpm) }
                self.processNextEntry(wpm: currentWpm)

            case .delay(let seconds):
                self.processingQueue.asyncAfter(deadline: .now() + seconds) { [weak self] in
                    self?.processNextEntry(wpm: currentWpm)
                }

            case .serialNumber:
                let num = self.serialNumber
                let text = self.formatSerialNumber(num, useCutNumbers: self.cutNumbersEnabled)
                DispatchQueue.main.async { self.serialNumber = num + 1 }
                self.sendTextInChunks(text, wpm: currentWpm)
            }
        }
    }

    /// Split text into 30-char chunks and send with pacing delays
    private func sendTextInChunks(_ text: String, wpm: Int) {
        let chunks = stride(from: 0, to: text.count, by: 30).map { offset -> String in
            let start = text.index(text.startIndex, offsetBy: offset)
            let end = text.index(start, offsetBy: min(30, text.count - offset))
            return String(text[start..<end])
        }

        sendChunkSequence(chunks, index: 0, wpm: wpm)
    }

    private func sendChunkSequence(_ chunks: [String], index: Int, wpm: Int) {
        guard index < chunks.count else {
            processNextEntry(wpm: wpm)
            return
        }

        let chunk = chunks[index]
        logger.debug("Sending chunk \(index + 1)/\(chunks.count): \"\(chunk)\"")

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            guard let onSendCW = self.onSendCW else {
                logger.error("onSendCW callback is nil!")
                self.processingQueue.async {
                    self.sendBuffer.removeAll()
                    self.processingTimer?.cancel()
                    self.processingTimer = nil
                    DispatchQueue.main.async {
                        self.isSending = false
                        self.onSendingDidEnd?()
                    }
                }
                return
            }

            onSendCW(chunk) { success in
                logger.debug("onSendCW completion: success=\(success) for chunk \"\(chunk)\"")
                guard success else {
                    logger.error("onSendCW failed for chunk \"\(chunk)\"")
                    self.processingQueue.async {
                        self.sendBuffer.removeAll()
                        self.processingTimer?.cancel()
                        self.processingTimer = nil
                        DispatchQueue.main.async {
                            self.isSending = false
                            self.onSendingDidEnd?()
                        }
                    }
                    return
                }

                self.onChunkSent?(chunk, wpm)

                let duration = MorseTiming.estimateDuration(chunk, wpm: wpm)
                let pacedDuration = duration * 1.12
                self.processingQueue.asyncAfter(deadline: .now() + pacedDuration) { [weak self] in
                    self?.sendChunkSequence(chunks, index: index + 1, wpm: wpm)
                }
            }
        }
    }
}

// MARK: - Morse Timing

/// Morse timing calculations for pacing (the radio does actual encoding).
/// Element counts from K3NG keyer for estimating transmission duration.
enum MorseTiming {
    /// Morse patterns expressed as element counts.
    /// Each dit = 1 element, each dah = 3 elements.
    /// Inter-element gap = 1 element (within character).
    /// Total "dit-length" count for each character including inter-element gaps.
    static let elementCounts: [Character: Int] = [
        // Each dit = 1, dah = 3, inter-element gap = 1. Sum within character.
        "A": 5,   // .- = 1+1+3 = 5
        "B": 9,   // -... = 3+1+1+1+1+1+1 = 9
        "C": 11,  // -.-. = 3+1+1+1+3+1+1 = 11
        "D": 7,   // -.. = 3+1+1+1+1 = 7
        "E": 1,   // . = 1
        "F": 9,   // ..-. = 1+1+1+1+3+1+1 = 9
        "G": 9,   // --. = 3+1+3+1+1 = 9
        "H": 7,   // .... = 1+1+1+1+1+1+1 = 7
        "I": 3,   // .. = 1+1+1 = 3
        "J": 13,  // .--- = 1+1+3+1+3+1+3 = 13
        "K": 9,   // -.- = 3+1+1+1+3 = 9
        "L": 9,   // .-.. = 1+1+3+1+1+1+1 = 9
        "M": 7,   // -- = 3+1+3 = 7
        "N": 5,   // -. = 3+1+1 = 5
        "O": 11,  // --- = 3+1+3+1+3 = 11
        "P": 11,  // .--. = 1+1+3+1+3+1+1 = 11
        "Q": 13,  // --.- = 3+1+3+1+1+1+3 = 13
        "R": 7,   // .-. = 1+1+3+1+1 = 7
        "S": 5,   // ... = 1+1+1+1+1 = 5
        "T": 3,   // - = 3
        "U": 7,   // ..- = 1+1+1+1+3 = 7
        "V": 9,   // ...- = 1+1+1+1+1+1+3 = 9
        "W": 9,   // .-- = 1+1+3+1+3 = 9
        "X": 11,  // -..- = 3+1+1+1+1+1+3 = 11
        "Y": 13,  // -.-- = 3+1+1+1+3+1+3 = 13
        "Z": 11,  // --.. = 3+1+3+1+1+1+1 = 11
        // Numbers
        "0": 19,  // ----- = 3+1+3+1+3+1+3+1+3 = 19
        "1": 17,  // .---- = 1+1+3+1+3+1+3+1+3 = 17
        "2": 15,  // ..--- = 1+1+1+1+3+1+3+1+3 = 15
        "3": 13,  // ...-- = 1+1+1+1+1+1+3+1+3 = 13
        "4": 11,  // ....- = 1+1+1+1+1+1+1+1+3 = 11
        "5": 9,   // ..... = 1+1+1+1+1+1+1+1+1 = 9
        "6": 11,  // -.... = 3+1+1+1+1+1+1+1+1 = 11
        "7": 13,  // --... = 3+1+3+1+1+1+1+1+1 = 13
        "8": 15,  // ---.. = 3+1+3+1+3+1+1+1+1 = 15
        "9": 17,  // ----. = 3+1+3+1+3+1+3+1+1 = 17
        // Punctuation
        "/": 13,  // -..-. = 3+1+1+1+1+1+3+1+1 = 13
        "?": 15,  // ..--.. = 1+1+1+1+3+1+3+1+1+1+1 = 15
        ".": 17,  // .-.-.- = 1+1+3+1+1+1+3+1+1+1+3 = 17
        ",": 19,  // --..-- = 3+1+3+1+1+1+1+1+3+1+3 = 19
        "=": 13,  // -...- = 3+1+1+1+1+1+1+1+3 = 13
        "-": 15,  // -....- = 3+1+1+1+1+1+1+1+1+1+3 = 15
        "(": 15,  // -.--. = 3+1+1+1+3+1+3+1+1 = 15
        ")": 17,  // -.--.- = 3+1+1+1+3+1+3+1+1+1+3 = 17
        "'": 19,  // .----. = 1+1+3+1+3+1+3+1+3+1+1 = 19
        ":": 17,  // ---... = 3+1+3+1+3+1+1+1+1+1+1 = 17
        "+": 13,  // .-.-. = 1+1+3+1+1+1+3+1+1 = 13
        "\"": 15, // .-..-. = 1+1+3+1+1+1+1+1+3+1+1 = 15
        "@": 17,  // .--.-. = 1+1+3+1+3+1+1+1+3+1+1 = 17
    ]

    /// Estimate how long it takes to transmit a string at a given WPM.
    /// Returns duration in seconds.
    static func estimateDuration(_ text: String, wpm: Int) -> TimeInterval {
        guard wpm > 0 else { return 0 }
        let ditMs = 1200.0 / Double(wpm)

        var totalElements = 0
        var prevWasSpace = false

        for char in text.uppercased() {
            if char == " " {
                // Word space = 7 dit-lengths (but 3 already counted as inter-char gap)
                totalElements += 4 // Add the extra 4 beyond inter-char gap
                prevWasSpace = true
            } else if let count = elementCounts[char] {
                if !prevWasSpace && totalElements > 0 {
                    // Inter-character gap = 3 dit-lengths
                    totalElements += 3
                }
                totalElements += count
                prevWasSpace = false
            }
            // Unknown chars are skipped
        }

        return (Double(totalElements) * ditMs) / 1000.0
    }
}

// MARK: - Int extension

private extension Int {
    func nonZeroOr(_ fallback: Int) -> Int {
        self == 0 ? fallback : self
    }
}
