import ArgumentParser
import Foundation
import SessionManager

struct DisconnectCommand: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "disconnect",
        abstract: "Disconnect from the radio"
    )

    @Flag(name: .long, help: "Clear saved session file")
    var clear: Bool = false

    @Flag(name: .long, help: "Verbose output")
    var verbose: Bool = false

    mutating func run() async throws {
        // Disconnect current session
        if let manager = CLIState.shared.manager {
            if verbose {
                print("Disconnecting...")
            }
            await manager.disconnect()
            CLIState.shared.manager = nil
            if verbose {
                print("Disconnected")
            }
        } else if verbose {
            print("No active session")
        }

        // Clear saved session if requested
        if clear {
            if SessionStore.hasSavedSession {
                try SessionStore.clear()
                if verbose {
                    print("Saved session cleared")
                }
            } else if verbose {
                print("No saved session to clear")
            }
        }

        print("Disconnected")
    }
}
