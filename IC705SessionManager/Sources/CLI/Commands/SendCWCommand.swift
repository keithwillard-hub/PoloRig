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
        let existingManager = CLIState.shared.manager
        let (manager, connectedInThisInvocation) = try await CLICommandSupport.ensureConnected(
            existingManager: existingManager,
            verbose: verbose
        )
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
                await CLICommandSupport.disconnectIfNeeded(
                    manager: manager,
                    connectedInThisInvocation: connectedInThisInvocation
                )
                print("Error: CW send failed")
                throw ExitCode.failure
            }

        } catch let error as RadioError {
            await CLICommandSupport.disconnectIfNeeded(
                manager: manager,
                connectedInThisInvocation: connectedInThisInvocation
            )
            print("CW send failed: \(error.description)")
            throw ExitCode.failure
        } catch {
            await CLICommandSupport.disconnectIfNeeded(
                manager: manager,
                connectedInThisInvocation: connectedInThisInvocation
            )
            print("CW send failed: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        await CLICommandSupport.disconnectIfNeeded(
            manager: manager,
            connectedInThisInvocation: connectedInThisInvocation
        )
    }
}
