import ArgumentParser
import Foundation
import SessionManager

@main
struct IC705SessionCLI: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "ic705-session-cli",
        abstract: "Run a persistent single-session IC-705 test sequence"
    )

    @Option(name: .long, help: "Radio IP address")
    var host: String?

    @Option(name: .long, help: "RS-BA1 username")
    var user: String?

    @Option(name: .long, help: "RS-BA1 password")
    var pass: String?

    @Option(name: .long, help: "Computer name")
    var name: String = "CLI"

    @Option(name: .long, help: "CW text to send")
    var text: String = "TEST DE AC0VW"

    @Flag(name: .long, help: "Verbose output")
    var verbose: Bool = false

    mutating func run() async throws {
        let session = try resolveSession()
        let config = ConnectionConfig(
            host: session.host,
            username: session.username,
            password: session.password,
            computerName: session.computerName
        )

        let stageHandler: (@Sendable (String) -> Void)?
        if verbose {
            stageHandler = { message in
                print("  [\(message)]")
            }
        } else {
            stageHandler = nil
        }

        print("Running persistent session sequence against \(config.host)...")

        do {
            let result = try await PersistentSequenceRunner.run(
                config: config,
                cwText: text.uppercased(),
                stageHandler: stageHandler
            )

            print("Connected to \(result.radioName)")
            print("CW Speed: \(result.cwSpeedWPM) WPM")
            print(String(format: "Frequency: %.3f MHz", Double(result.frequencyHz) / 1_000_000.0))
            print("Mode: \(result.mode)")
            print("CW sent: \(result.cwSent ? "yes" : "no")")
        } catch let error as RadioError {
            print("Sequence failed: \(error.description)")
            throw ExitCode.failure
        } catch {
            print("Sequence failed: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }

    private func resolveSession() throws -> StoredSession {
        var targetHost = host
        var targetUser = user
        var targetPass = pass

        if targetHost == nil || targetUser == nil || targetPass == nil, let saved = try SequenceSessionStore.load() {
            targetHost = targetHost ?? saved.host
            targetUser = targetUser ?? saved.username
            targetPass = targetPass ?? saved.password
        }

        guard let host = targetHost, !host.isEmpty else {
            throw ValidationError("Missing required option: --host")
        }
        guard let user = targetUser, !user.isEmpty else {
            throw ValidationError("Missing required option: --user")
        }
        guard let pass = targetPass, !pass.isEmpty else {
            throw ValidationError("Missing required option: --pass")
        }

        return StoredSession(host: host, username: user, password: pass, computerName: name)
    }
}

private struct StoredSession: Codable {
    let host: String
    let username: String
    let password: String
    let computerName: String
}

private enum SequenceSessionStore {
    private static let sessionFileName = "ic705-session.json"

    static var sessionFileURL: URL {
        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser
        let configDir = homeDir.appendingPathComponent(".config/ic705", isDirectory: true)
        if !fileManager.fileExists(atPath: configDir.path) {
            try? fileManager.createDirectory(at: configDir, withIntermediateDirectories: true)
        }
        return configDir.appendingPathComponent(sessionFileName)
    }

    static func load() throws -> StoredSession? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionFileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: sessionFileURL)
        let decoder = JSONDecoder()
        return try decoder.decode(StoredSession.self, from: data)
    }
}

private struct ValidationError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
