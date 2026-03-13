import AVFoundation
import Foundation
import os

private let logger = Logger(subsystem: "com.ic705cwlogger", category: "CWSidetone")

/// Local audio sidetone generator so the operator hears what's being sent.
/// Uses AVAudioEngine to generate a sine wave at the configured CW pitch.
/// Adapted from wfview's cwSidetone.cpp approach.
@Observable
final class CWSidetone {
    // MARK: - Properties

    /// Whether sidetone playback is enabled
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "sidetoneEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "sidetoneEnabled") }
    }

    /// Sidetone pitch in Hz (300-900, default 600)
    var pitchHz: Int {
        get {
            let val = UserDefaults.standard.integer(forKey: "sidetonePitch")
            return val == 0 ? 600 : val
        }
        set { UserDefaults.standard.set(newValue, forKey: "sidetonePitch") }
    }

    /// Volume level (0.0-1.0, default 0.8)
    var volume: Float = 0.8

    /// Currently playing sidetone
    private(set) var isPlaying = false

    // MARK: - Audio Engine

    private var audioEngine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var phase: Double = 0.0
    private var toneActive = false
    private var fadeGain: Float = 0.0
    private let fadeSteps: Float = 240.0 // ~5ms fade at 48kHz
    private let playbackQueue = DispatchQueue(label: "com.ic705cwlogger.sidetone")
    private var stopRequested = false

    // MARK: - Morse Lookup Table

    static let morseTable: [Character: String] = [
        "A": ".-",    "B": "-...",  "C": "-.-.",  "D": "-..",   "E": ".",     "F": "..-.",
        "G": "--.",   "H": "....",  "I": "..",    "J": ".---",  "K": "-.-",   "L": ".-..",
        "M": "--",    "N": "-.",    "O": "---",   "P": ".--.",  "Q": "--.-",  "R": ".-.",
        "S": "...",   "T": "-",    "U": "..-",   "V": "...-",  "W": ".--",   "X": "-..-",
        "Y": "-.--",  "Z": "--..",
        "0": "-----", "1": ".----", "2": "..---", "3": "...--", "4": "....-",
        "5": ".....", "6": "-....", "7": "--...", "8": "---..", "9": "----.",
        "/": "-..-.", "?": "..--..", ".": ".-.-.-", ",": "--..--", "=": "-...-",
        "-": "-....-", "(": "-.--.", ")": "-.--.-", "'": ".----.", ":": "---...",
        "+": ".-.-.", "\"": ".-..-.", "@": ".--.-.",
    ]

    // MARK: - Public API

    /// Play sidetone for a text string at the given WPM.
    /// Runs asynchronously on a background queue.
    func playText(_ text: String, wpm: Int) {
        guard isEnabled else { return }

        stopRequested = false
        isPlaying = true

        playbackQueue.async { [weak self] in
            guard let self else { return }

            self.setupEngine()

            let ditMs = 1200.0 / Double(wpm)

            for (i, char) in text.uppercased().enumerated() {
                if self.stopRequested { break }

                if char == " " {
                    // Word space = 7 dit-times, minus 3 already from previous inter-char gap
                    self.silence(ms: ditMs * 4)
                    continue
                }

                guard let pattern = Self.morseTable[char] else { continue }

                for (j, element) in pattern.enumerated() {
                    if self.stopRequested { break }

                    let isDah = element == "-"
                    let toneDuration = isDah ? ditMs * 3 : ditMs

                    self.playTone(durationMs: toneDuration)

                    // Inter-element gap (within character)
                    if j < pattern.count - 1 {
                        self.silence(ms: ditMs)
                    }
                }

                // Inter-character gap (3 dit-times) unless end of text
                if !self.stopRequested && i < text.count - 1 {
                    let nextChar = text[text.index(text.startIndex, offsetBy: i + 1)]
                    if nextChar != " " {
                        self.silence(ms: ditMs * 3)
                    }
                }
            }

            self.teardownEngine()
            DispatchQueue.main.async { self.isPlaying = false }
        }
    }

    /// Immediately stop sidetone playback
    func stop() {
        stopRequested = true
        playbackQueue.async { [weak self] in
            self?.teardownEngine()
            DispatchQueue.main.async { self?.isPlaying = false }
        }
    }

    // MARK: - Audio Engine Management

    private func setupEngine() {
        let engine = AVAudioEngine()
        let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        let pitch = Double(pitchHz)
        let vol = volume

        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }

            let bufferList = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let buffer = bufferList[0]
            let ptr = buffer.mData!.assumingMemoryBound(to: Float.self)
            let twoPi = 2.0 * Double.pi
            let phaseIncrement = twoPi * pitch / sampleRate

            for frame in 0..<Int(frameCount) {
                // Fade envelope to prevent clicks
                let targetGain: Float = self.toneActive ? vol : 0.0
                let fadeRate: Float = 1.0 / self.fadeSteps
                if self.fadeGain < targetGain {
                    self.fadeGain = min(self.fadeGain + fadeRate, targetGain)
                } else if self.fadeGain > targetGain {
                    self.fadeGain = max(self.fadeGain - fadeRate, targetGain)
                }

                let sample = Float(sin(self.phase)) * self.fadeGain
                ptr[frame] = sample
                self.phase += phaseIncrement
                if self.phase >= twoPi { self.phase -= twoPi }
            }

            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
        } catch {
            logger.error("Failed to start audio engine: \(error.localizedDescription)")
        }

        self.audioEngine = engine
        self.sourceNode = node
        self.phase = 0
        self.fadeGain = 0
        self.toneActive = false
    }

    private func teardownEngine() {
        toneActive = false
        // Brief fade-out
        Thread.sleep(forTimeInterval: 0.01)
        audioEngine?.stop()
        if let node = sourceNode {
            audioEngine?.detach(node)
        }
        audioEngine = nil
        sourceNode = nil
    }

    // MARK: - Tone Control

    private func playTone(durationMs: Double) {
        toneActive = true
        Thread.sleep(forTimeInterval: durationMs / 1000.0)
        toneActive = false
    }

    private func silence(ms: Double) {
        Thread.sleep(forTimeInterval: ms / 1000.0)
    }
}
