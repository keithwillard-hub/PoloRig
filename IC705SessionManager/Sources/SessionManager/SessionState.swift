import Foundation

/// Represents the current state of the IC-705 session
public enum SessionState: Equatable, CustomStringConvertible {
    /// No session, ready to connect
    case disconnected

    /// In the process of establishing connection
    case connecting

    /// Connected and ready for operations
    case connected(radioName: String)

    /// Currently querying radio status (frequency/mode)
    case queryingStatus

    /// Currently sending CW
    case sendingCW

    /// In the process of disconnecting
    case disconnecting

    public var isConnected: Bool {
        switch self {
        case .connected, .queryingStatus, .sendingCW:
            return true
        default:
            return false
        }
    }

    public var isBusy: Bool {
        switch self {
        case .connecting, .queryingStatus, .sendingCW, .disconnecting:
            return true
        default:
            return false
        }
    }

    public var radioName: String? {
        switch self {
        case .connected(let name):
            return name
        default:
            return nil
        }
    }

    public var description: String {
        switch self {
        case .disconnected:
            return "disconnected"
        case .connecting:
            return "connecting"
        case .connected(let name):
            return "connected(\(name))"
        case .queryingStatus:
            return "queryingStatus"
        case .sendingCW:
            return "sendingCW"
        case .disconnecting:
            return "disconnecting"
        }
    }
}

/// Valid state transitions for the session state machine
extension SessionState {
    /// Check if a transition from this state to the target state is valid
    func canTransition(to newState: SessionState) -> Bool {
        switch (self, newState) {
        // From disconnected
        case (.disconnected, .connecting),
             (.disconnected, .disconnected):
            return true

        // From connecting
        case (.connecting, .connected),
             (.connecting, .disconnected),
             (.connecting, .disconnecting):
            return true

        // From connected - can go to any operational state or disconnect
        case (.connected, .queryingStatus),
             (.connected, .sendingCW),
             (.connected, .disconnecting),
             (.connected, .disconnected),
             (.connected, .connected):  // Re-connection
            return true

        // From queryingStatus
        case (.queryingStatus, .connected),
             (.queryingStatus, .disconnecting),
             (.queryingStatus, .disconnected),
             (.queryingStatus, .sendingCW):  // Preempt status query with CW
            return true

        // From sendingCW
        case (.sendingCW, .connected),
             (.sendingCW, .disconnecting),
             (.sendingCW, .disconnected):
            return true

        // From disconnecting
        case (.disconnecting, .disconnected):
            return true

        default:
            return false
        }
    }
}
