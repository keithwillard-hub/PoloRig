import ArgumentParser
import Foundation
import SessionManager

enum CLICommandSupport {
    static func ensureConnected(
        existingManager: SessionManager?,
        verbose: Bool,
        autoConnectMessage: String? = nil
    ) async throws -> (manager: SessionManager, connectedInThisInvocation: Bool) {
        let manager = existingManager ?? SessionManager()

        if verbose {
            manager.stageHandler = { message in
                print("  [\(message)]")
            }
        } else {
            manager.stageHandler = nil
        }

        guard !manager.isConnected else {
            return (manager, false)
        }

        guard let saved = try SessionStore.load() else {
            print("Error: Not connected and no saved session found")
            print("Run 'ic705-cli connect --host <ip> --user <user> --pass <pass> --save' first")
            throw ExitCode.failure
        }

        if let autoConnectMessage {
            print(autoConnectMessage)
        } else if verbose {
            print("Loading saved session...")
        }

        manager.configure(
            host: saved.host,
            username: saved.username,
            password: saved.password,
            computerName: saved.computerName
        )

        return (manager, true)
    }

    static func disconnectIfNeeded(
        manager: SessionManager,
        connectedInThisInvocation: Bool
    ) async {
        guard connectedInThisInvocation else { return }
        await manager.disconnect()
        if CLIState.shared.manager === manager {
            CLIState.shared.manager = nil
        }
    }
}
