import ArgumentParser
import Foundation
import SessionManager
import Darwin

struct WatchCommand: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "watch",
        abstract: "Monitor radio status continuously"
    )

    @Option(name: .long, help: "Update interval in seconds", transform: { Double($0) ?? 1.0 })
    var interval: Double = 1.0

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

            print("Auto-connecting using saved session...")

            do {
                _ = try await manager.connect(
                    host: saved.host,
                    username: saved.username,
                    password: saved.password,
                    computerName: saved.computerName
                )
                print("Connected")
            } catch let error as RadioError {
                print("Auto-connect failed: \(error.description)")
                throw ExitCode.failure
            } catch {
                print("Auto-connect failed: \(error.localizedDescription)")
                throw ExitCode.failure
            }
        }

        print("Watching radio status (press Ctrl+C to stop)...")
        print("")

        // Set up signal handler for graceful exit
        signal(SIGINT) { _ in
            print("\nStopping...")
            Darwin.exit(0)
        }

        // Loop until interrupted
        while true {
            do {
                let result = try await manager.queryStatus()

                if json {
                    let encoder = JSONEncoder()
                    let data = try encoder.encode(result)
                    print(String(data: data, encoding: .utf8)!)
                } else {
                    let freqMHz = Double(result.frequencyHz) / 1_000_000.0
                    print(String(format: "\r%.3f MHz | %-6s          ", freqMHz, result.mode), terminator: "")
                    fflush(stdout)
                }

            } catch let error as RadioError {
                print("\nStatus query failed: \(error.description)")
            } catch {
                print("\nStatus query failed: \(error.localizedDescription)")
            }

            // Wait for next interval
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }
}
