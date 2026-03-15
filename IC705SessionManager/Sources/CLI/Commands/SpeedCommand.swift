import ArgumentParser
import Foundation
import SessionManager

struct SpeedCommand: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "speed",
        abstract: "Query CW speed"
    )

    @Flag(name: .long, help: "Verbose output")
    var verbose: Bool = false

    mutating func run() async throws {
        let existingManager = CLIState.shared.manager
        let (manager, connectedInThisInvocation) = try await CLICommandSupport.ensureConnected(
            existingManager: existingManager,
            verbose: verbose
        )
        CLIState.shared.manager = manager

        do {
            let speed = try await manager.queryCWSpeed()
            print("CW Speed: \(speed) WPM")
        } catch let error as RadioError {
            await CLICommandSupport.disconnectIfNeeded(
                manager: manager,
                connectedInThisInvocation: connectedInThisInvocation
            )
            print("CW speed query failed: \(error.description)")
            throw ExitCode.failure
        } catch {
            await CLICommandSupport.disconnectIfNeeded(
                manager: manager,
                connectedInThisInvocation: connectedInThisInvocation
            )
            print("CW speed query failed: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        await CLICommandSupport.disconnectIfNeeded(
            manager: manager,
            connectedInThisInvocation: connectedInThisInvocation
        )
    }
}
