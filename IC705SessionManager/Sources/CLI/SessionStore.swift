import Foundation
import SessionManager

/// Manages persistent storage of session credentials
public struct SessionStore {
    private static let sessionFileName = "ic705-session.json"

    /// URL to the session file
    public static var sessionFileURL: URL {
        let fileManager = FileManager.default

        // Use ~/.config/ic705/ on macOS/Linux, or ~/.ic705/ as fallback
        let homeDir = fileManager.homeDirectoryForCurrentUser
        let configDir = homeDir.appendingPathComponent(".config/ic705", isDirectory: true)

        // Ensure directory exists
        if !fileManager.fileExists(atPath: configDir.path) {
            try? fileManager.createDirectory(at: configDir, withIntermediateDirectories: true)
        }

        return configDir.appendingPathComponent(sessionFileName)
    }

    /// Saved session data
    public struct SessionData: Codable {
        public let host: String
        public let username: String
        public let password: String
        public let computerName: String
        public let savedAt: Date

        public init(host: String, username: String, password: String, computerName: String = "CLI") {
            self.host = host
            self.username = username
            self.password = password
            self.computerName = computerName
            self.savedAt = Date()
        }

        public var config: ConnectionConfig {
            ConnectionConfig(
                host: host,
                username: username,
                password: password,
                computerName: computerName
            )
        }
    }

    /// Save session to disk
    public static func save(session: SessionData) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(session)
        try data.write(to: sessionFileURL, options: .atomic)
    }

    /// Load session from disk
    public static func load() throws -> SessionData? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionFileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: sessionFileURL)
        let decoder = JSONDecoder()
        return try decoder.decode(SessionData.self, from: data)
    }

    /// Clear saved session
    public static func clear() throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: sessionFileURL.path) {
            try fileManager.removeItem(at: sessionFileURL)
        }
    }

    /// Check if a saved session exists
    public static var hasSavedSession: Bool {
        FileManager.default.fileExists(atPath: sessionFileURL.path)
    }

    /// Print the session file path
    public static func printSessionPath() {
        print("Session file: \(sessionFileURL.path)")
    }
}
