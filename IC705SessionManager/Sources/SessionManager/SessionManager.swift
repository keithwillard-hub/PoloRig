import Foundation

public final class SessionManager {
    public var stageHandler: (@Sendable (String) -> Void)? {
        didSet {
            session?.stageHandler = stageHandler
        }
    }

    private var config: ConnectionConfig?
    private var session: PersistentRadioSession?

    public init() {}

    public func configure(
        host: String,
        username: String,
        password: String,
        computerName: String = "CLI"
    ) {
        config = ConnectionConfig(
            host: host,
            username: username,
            password: password,
            computerName: computerName
        )
    }

    public func connect(
        host: String,
        username: String,
        password: String,
        computerName: String = "CLI"
    ) async throws -> String {
        configure(
            host: host,
            username: username,
            password: password,
            computerName: computerName
        )
        return try await ensureSession().connect().radioName
    }

    public func queryStatus() async throws -> StatusResult {
        try await ensureSession().queryStatus()
    }

    public func queryCWSpeed() async throws -> Int {
        try await ensureSession().queryCWSpeed()
    }

    public func sendCW(_ text: String) async throws -> Bool {
        try await ensureSession().sendCW(text)
    }

    public func setCWSpeed(_ wpm: Int) async throws {
        try await ensureSession().setCWSpeed(wpm)
    }

    public func stopCW() async throws {
        try await ensureSession().stopCW()
    }

    public func disconnect() async {
        if let session {
            await session.disconnect()
        }
        session = nil
        config = nil
    }

    public func getCurrentConfig() -> ConnectionConfig? {
        config
    }

    public var isConnected: Bool {
        session != nil
    }

    private func ensureSession() throws -> PersistentRadioSession {
        if let session {
            return session
        }
        guard let config else {
            throw RadioError.notConnected
        }
        let session = PersistentRadioSession(config: config)
        session.stageHandler = stageHandler
        self.session = session
        return session
    }
}
