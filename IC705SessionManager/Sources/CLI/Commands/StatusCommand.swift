import ArgumentParser
import Foundation
import SessionManager

struct StatusCommand: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Query radio status (frequency and mode)"
    )

    @Flag(name: .long, help: "Verbose output")
    var verbose: Bool = false

    @Flag(name: .long, help: "Output as JSON")
    var json: Bool = false

    mutating func run() async throws {
        let manager = CLIState.shared.manager ?? SessionManager()
        CLIState.shared.manager = manager

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

        // Query status
        do {
            let result = try await manager.queryStatus()

            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = .prettyPrinted
                let data = try encoder.encode(result)
                print(String(data: data, encoding: .utf8)!)
            } else {
                let freqMHz = Double(result.frequencyHz) / 1_000_000.0
                print(String(format: "Frequency: %.3f MHz", freqMHz))
                print("Mode: \(result.mode)")
            }

        } catch let error as RadioError {
            print("Status query failed: \(error.description)")
            throw ExitCode.failure
        } catch {
            print("Status query failed: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
}
