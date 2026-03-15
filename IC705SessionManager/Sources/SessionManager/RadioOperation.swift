import Foundation
import Transport

/// Protocol for all radio operations
public protocol RadioOperation {
    /// The type of result this operation produces
    associatedtype Result

    /// Execute the operation
    /// - Parameter context: The session context providing access to connections
    /// - Returns: The operation result
    /// - Throws: RadioError if the operation fails
    func execute(context: SessionContext) async throws -> Result

    /// The name of this operation (for logging/debugging)
    var name: String { get }
}

/// Context provided to operations during execution
public final class SessionContext {
    /// The control connection (port 50001)
    public var control: UDPControl?

    /// The serial connection (port 50002)
    public var serial: UDPSerial?

    /// Connection configuration
    public let config: ConnectionConfig

    public init(config: ConnectionConfig) {
        self.config = config
    }
}

/// Configuration for connecting to the radio
public struct ConnectionConfig: Equatable {
    public let host: String
    public let username: String
    public let password: String
    public let computerName: String

    public init(host: String, username: String, password: String, computerName: String = "CLI") {
        self.host = host
        self.username = username
        self.password = password
        self.computerName = computerName
    }
}

/// Result of a status query
public struct StatusResult: Equatable, Encodable {
    public let frequencyHz: Int
    public let mode: String
    public let isConnected: Bool

    public init(frequencyHz: Int, mode: String, isConnected: Bool) {
        self.frequencyHz = frequencyHz
        self.mode = mode
        self.isConnected = isConnected
    }
}

// MARK: - Concrete Operations

/// Connect to the radio
public final class ConnectOperation: RadioOperation {
    public let name = "connect"

    public init() {}

    public func execute(context: SessionContext) async throws -> String {
        let config = context.config

        // Create control connection
        let control = UDPControl(
            host: config.host,
            port: 50001,
            userName: config.username,
            password: config.password,
            computerName: config.computerName
        )

        // Use continuation for async callback
        return try await withCheckedThrowingContinuation { continuation in
            var isSettled = false

            // Set timeout
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: UInt64(12 * 1_000_000_000))
                guard !isSettled else { return }
                isSettled = true
                continuation.resume(throwing: RadioError.timeout(operation: "connect", duration: 12.0))
            }

            control.onAuthenticated = {
                timeoutTask.cancel()
                guard !isSettled else { return }
                isSettled = true
                continuation.resume(returning: control.radioName)
            }

            control.onDisconnect = {
                timeoutTask.cancel()
                guard !isSettled else { return }
                isSettled = true
                continuation.resume(throwing: RadioError.networkError(NSError(domain: "SessionManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Connection closed during setup"])))
            }

            context.control = control
            control.connect()
        }
    }
}

/// Open the serial port for CI-V communication
public final class OpenSerialOperation: RadioOperation {
    public let name = "openSerial"

    public init() {}

    public func execute(context: SessionContext) async throws -> Void {
        guard let control = context.control else {
            throw RadioError.notConnected
        }

        let serial = UDPSerial(
            host: context.config.host,
            port: control.remoteCIVPort
        )

        return try await withCheckedThrowingContinuation { continuation in
            var isSettled = false

            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: UInt64(3 * 1_000_000_000))
                guard !isSettled else { return }
                isSettled = true
                continuation.resume(throwing: RadioError.timeout(operation: "openSerial", duration: 3.0))
            }

            serial.onSerialReady = {
                timeoutTask.cancel()
                guard !isSettled else { return }
                isSettled = true
                continuation.resume(returning: ())
            }

            context.serial = serial
            serial.connect()
        }
    }
}

/// Query radio status (frequency and mode)
public final class QueryStatusOperation: RadioOperation {
    public let name = "queryStatus"

    public init() {}

    public func execute(context: SessionContext) async throws -> StatusResult {
        guard let serial = context.serial else {
            throw RadioError.notConnected
        }

        var frequencyHz: Int?
        var modeLabel: String?

        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<StatusResult, Error>) in
            var isSettled = false

            // Set timeout
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: UInt64(3 * 1_000_000_000))
                guard !isSettled else { return }
                isSettled = true
                continuation.resume(throwing: RadioError.timeout(operation: "queryStatus", duration: 3.0))
            }

            // Set up CI-V response handler
            serial.onCIVReceived = { civData in
                guard civData.count >= 7,
                      civData[0] == 0xFE,
                      civData[1] == 0xFE,
                      civData[civData.count - 1] == 0xFD else {
                    return
                }

                let command = civData[4]

                switch command {
                case CIV.Command.readFrequency:
                    guard civData.count >= 11 else { return }
                    let freqBytes = Array(civData[5..<10])
                    if let hz = CIV.Frequency.parseHz(from: freqBytes) {
                        frequencyHz = hz
                    }

                case CIV.Command.readMode:
                    guard civData.count >= 7 else { return }
                    let modeByte = civData[5]
                    if let mode = CIV.Mode(rawValue: modeByte) {
                        modeLabel = mode.label
                    }

                default:
                    return
                }

                // Check if we have both values
                if let freq = frequencyHz, let mode = modeLabel, !isSettled {
                    isSettled = true
                    timeoutTask.cancel()
                    continuation.resume(returning: StatusResult(frequencyHz: freq, mode: mode, isConnected: true))
                }
            }

            // Send frequency request
            let freqFrame = CIV.buildFrame(command: CIV.Command.readFrequency)
            serial.sendCIV(data: freqFrame, expectsReply: true, completion: nil)

            // Send mode request
            let modeFrame = CIV.buildFrame(command: CIV.Command.readMode)
            serial.sendCIV(data: modeFrame, expectsReply: true, completion: nil)
        }

        // Clear the handler
        serial.onCIVReceived = nil

        return result
    }
}

/// Send CW text
public final class SendCWOperation: RadioOperation {
    public let text: String
    public let name = "sendCW"

    public init(text: String) {
        self.text = text.uppercased()
    }

    public func execute(context: SessionContext) async throws -> Bool {
        guard let serial = context.serial else {
            throw RadioError.notConnected
        }

        // Validate text
        guard !text.isEmpty, text.count <= 30 else {
            throw RadioError.invalidResponse  // Or a more specific error
        }

        // Build CI-V frame
        let asciiBytes = Array(text.utf8).map { UInt8($0) }
        let frame = CIV.buildFrame(command: CIV.Command.sendCW, data: asciiBytes)

        // Flush any pending commands to prioritize CW
        serial.flushQueue()

        return try await withCheckedThrowingContinuation { continuation in
            var isSettled = false

            // Set timeout (estimate based on CW speed + margin)
            let timeoutDuration: TimeInterval = max(Double(text.count) * 0.1, 1.0)
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: UInt64(timeoutDuration * 1_000_000_000))
                guard !isSettled else { return }
                isSettled = true
                continuation.resume(returning: false)
            }

            // Send the CW command
            serial.sendCIV(data: frame, expectsReply: false) { success in
                timeoutTask.cancel()
                guard !isSettled else { return }
                isSettled = true
                continuation.resume(returning: success)
            }

            // Resume background traffic after sending
            Task {
                try await Task.sleep(nanoseconds: UInt64(timeoutDuration * 1_000_000_000))
                serial.resumeDeferredBackgroundTraffic()
            }
        }
    }
}

/// Disconnect from the radio
public final class DisconnectOperation: RadioOperation {
    public let name = "disconnect"
    public let clearSession: Bool

    public init(clearSession: Bool = true) {
        self.clearSession = clearSession
    }

    public func execute(context: SessionContext) async throws -> Void {
        // Disconnect serial first
        context.serial?.disconnect()
        context.serial = nil

        // Then disconnect control
        context.control?.disconnect()
        context.control = nil

        // Small delay to let disconnect packets send
        try await Task.sleep(nanoseconds: 300_000_000) // 0.3s

        return ()
    }
}
