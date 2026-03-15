import Foundation
import SessionManager

/// Shared state for CLI commands
final class CLIState {
    static let shared = CLIState()

    var manager: SessionManager?

    private init() {}
}
