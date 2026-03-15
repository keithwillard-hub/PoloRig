import Foundation
import Transport
import os

private let logger = Logger(subsystem: "com.ic705.session", category: "SessionManager")

/// Session manager for IC-705 radio control using a serial dispatch queue
public final class SessionManager {
    // MARK: - Properties

    /// Serial queue for thread-safe operations
    private let queue = DispatchQueue(label: "com.ic705.session.manager", qos: .userInitiated)

    /// Current state of the session
    public private(set) var state: SessionState = .disconnected

    /// Configuration for the current session
    private var config: ConnectionConfig?

    /// Context shared with operations
    private var context: SessionContext?

    /// Handler called when state changes
    public var stateChangeHandler: (@Sendable (SessionState, SessionState) -> Void)?

    /// Handler called for stage updates during operations
    public var stageHandler: (@Sendable (String) -> Void)?

    // MARK: - Initialization

    public init() {}

    // MARK: - Public API

    /// Connect to the radio
    public func connect(
        host: String,
        username: String,
        password: String,
        computerName: String = "CLI"
    ) async throws -> String {
        // Check current state
        guard case .disconnected = state else {
            if case .connected = state {
                throw RadioError.alreadyConnected
            }
            throw RadioError.alreadyConnecting
        }

        // Transition to connecting
        transition(to: .connecting)

        // Create config and context
        let newConfig = ConnectionConfig(
            host: host,
            username: username,
            password: password,
            computerName: computerName
        )
        config = newConfig
        let ctx = SessionContext(config: newConfig)
        context = ctx

        do {
            // Step 1: Connect control port
            stageHandler?("Connecting to \(host)...")
            let controlOp = ConnectOperation()
            let radioName = try await controlOp.execute(context: ctx)

            // Step 2: Open serial port
            stageHandler?("Opening CI-V stream...")
            let serialOp = OpenSerialOperation()
            _ = try await serialOp.execute(context: ctx)

            // Success - set connected state
            transition(to: .connected(radioName: radioName))

            return radioName

        } catch {
            // Clean up on failure
            await disconnect()
            throw error
        }
    }

    /// Query current radio status (frequency and mode)
    public func queryStatus() async throws -> StatusResult {
        guard state.isConnected else {
            throw RadioError.notConnected
        }

        let previousState = state
        transition(to: .queryingStatus)

        guard let ctx = context else {
            transition(to: previousState)
            throw RadioError.notConnected
        }

        do {
            let op = QueryStatusOperation()
            let result = try await op.execute(context: ctx)
            transition(to: previousState)
            return result
        } catch {
            transition(to: previousState)
            throw error
        }
    }

    /// Send CW text
    public func sendCW(_ text: String) async throws -> Bool {
        guard state.isConnected else {
            throw RadioError.notConnected
        }

        let previousState = state
        transition(to: .sendingCW)

        guard let ctx = context else {
            transition(to: previousState)
            throw RadioError.notConnected
        }

        do {
            let op = SendCWOperation(text: text)
            let success = try await op.execute(context: ctx)
            transition(to: previousState)
            return success
        } catch {
            transition(to: previousState)
            throw error
        }
    }

    /// Disconnect from the radio
    public func disconnect() async {
        guard state != .disconnected, state != .disconnecting else {
            return
        }

        transition(to: .disconnecting)

        // Execute disconnect operation if we have a context
        if let ctx = context {
            let op = DisconnectOperation()
            _ = try? await op.execute(context: ctx)
        }

        // Clear state
        context = nil
        config = nil

        transition(to: .disconnected)
    }

    /// Get current connection info
    public func getCurrentConfig() -> ConnectionConfig? {
        return config
    }

    /// Check if connected
    public var isConnected: Bool {
        state.isConnected
    }

    /// Get current radio name if connected
    public var currentRadioName: String? {
        state.radioName
    }

    // MARK: - Private Methods

    /// Transition to a new state if valid
    private func transition(to newState: SessionState) {
        let oldState = state
        guard oldState.canTransition(to: newState) else {
            logger.warning("Invalid state transition: \(oldState.description) -> \(newState.description)")
            return
        }
        state = newState
        logger.info("State changed: \(oldState.description) -> \(newState.description)")
        stateChangeHandler?(oldState, newState)
    }
}
