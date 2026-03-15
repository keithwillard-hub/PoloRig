import ArgumentParser
import Foundation
import SessionManager

struct ConnectCommand: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "connect",
        abstract: "Connect to the IC-705 radio"
    )

    @Option(name: .long, help: "Radio IP address")
    var host: String?

    @Option(name: .long, help: "RS-BA1 username")
    var user: String?

    @Option(name: .long, help: "RS-BA1 password")
    var pass: String?

    @Option(name: .long, help: "Computer name (default: CLI)")
    var name: String = "CLI"

    @Flag(name: .long, help: "Save credentials for future commands")
    var save: Bool = false

    @Flag(name: .long, help: "Verbose output")
    var verbose: Bool = false

    mutating func run() async throws {
        var targetHost = host
        var targetUser = user
        var targetPass = pass

        // Load saved session if credentials not provided
        if targetHost == nil || targetUser == nil || targetPass == nil {
            if let saved = try SessionStore.load() {
                if verbose {
                    print("Loading saved session from \(saved.savedAt)")
                }
                targetHost = targetHost ?? saved.host
                targetUser = targetUser ?? saved.username
                targetPass = targetPass ?? saved.password
            }
        }

        // Validate we have all credentials
        guard let host = targetHost, !host.isEmpty else {
            print("Error: Host is required (use --host or save a session)")
            throw ValidationError("Missing required option: --host")
        }

        guard let user = targetUser, !user.isEmpty else {
            print("Error: Username is required (use --user or save a session)")
            throw ValidationError("Missing required option: --user")
        }

        guard let pass = targetPass, !pass.isEmpty else {
            print("Error: Password is required (use --pass or save a session)")
            throw ValidationError("Missing required option: --pass")
        }

        let manager = SessionManager()
        CLIState.shared.manager = manager

        if verbose {
            manager.stageHandler = { message in
                print("  [\(message)]")
            }
        }

        print("Connecting to \(host)...")

        do {
            let radioName = try await manager.connect(
                host: host,
                username: user,
                password: pass,
                computerName: name
            )

            print("Connected to \(radioName)")

            if save {
                let session = SessionStore.SessionData(
                    host: host,
                    username: user,
                    password: pass,
                    computerName: name
                )
                try SessionStore.save(session: session)
                print("Session saved to \(SessionStore.sessionFileURL.path)")
            }

            await manager.disconnect()
            CLIState.shared.manager = nil
            if verbose {
                print("Disconnected cleanly")
            }

        } catch let error as RadioError {
            await manager.disconnect()
            CLIState.shared.manager = nil
            print("Connection failed: \(error.description)")
            throw ExitCode.failure
        } catch {
            await manager.disconnect()
            CLIState.shared.manager = nil
            print("Connection failed: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
}

// Simple validation error
struct ValidationError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) {
        self.description = message
    }
}
