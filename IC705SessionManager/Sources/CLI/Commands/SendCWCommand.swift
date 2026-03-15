import ArgumentParser
import Foundation
import SessionManager

struct SendCWCommand: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "send-cw",
        abstract: "Send CW text via the radio"
    )

    @Argument(help: "Text to send (max 30 characters)")
    var text: String

    @Flag(name: .long, help: "Verbose output")
    var verbose: Bool = false

    mutating func run() async throws {
        let manager = CLIState.shared.manager ?? SessionManager()
        CLIState.shared.manager = manager

        // Validate text
        let trimmed = text.uppercased()
        guard !trimmed.isEmpty else {
            print("Error: Text cannot be empty")
            throw ExitCode.failure
        }

        guard trimmed.count <= 30 else {
            print("Error: Text must be 30 characters or less (got \(trimmed.count))")
            throw ExitCode.failure
        }

        // Check if we need to connect first
        let isConnected = manager.isConnected

        if !isConnected {
            // Try to load saved session
            guard let saved = try SessionStore.load() else {
                print("Error: Not connected and no saved session found")
                print("Run 'ic705-cli connect --host <ip> --user <user> --pass <pass>' first")
                throw ExitCode.failure
            }

            if verbose {
                print("Auto-connecting using saved session...")
            }

            do {
                _ = try await manager.connect(
                    host: saved.host,
                    username: saved.username,
                    password: saved.password,
                    computerName: saved.computerName
                )
            } catch let error as RadioError {
                print("Auto-connect failed: \(error.description)")
                throw ExitCode.failure
            } catch {
                print("Auto-connect failed: \(error.localizedDescription)")
                throw ExitCode.failure
            }
        }

        // Send CW
        if verbose {
            print("Sending CW: '\(trimmed)'")
        }

        do {
            let success = try await manager.sendCW(trimmed)

            if success {
                if verbose {
                    print("CW sent successfully")
                }
            } else {
                print("Error: CW send failed")
                throw ExitCode.failure
            }

        } catch let error as RadioError {
            print("CW send failed: \(error.description)")
            throw ExitCode.failure
        } catch {
            print("CW send failed: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
}
