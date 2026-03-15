import Foundation

/// Errors that can occur during radio operations
public enum RadioError: Error, CustomStringConvertible {
    case notConnected
    case alreadyConnecting
    case alreadyConnected
    case timeout(operation: String, duration: TimeInterval)
    case authenticationFailed
    case radioBusy
    case networkError(Error)
    case invalidResponse
    case operationCancelled
    case operationInProgress(String)
    case invalidState(String)

    public var description: String {
        switch self {
        case .notConnected:
            return "Not connected to radio"
        case .alreadyConnecting:
            return "Already connecting to radio"
        case .alreadyConnected:
            return "Already connected to radio"
        case .timeout(let operation, let duration):
            return "Operation '\(operation)' timed out after \(String(format: "%.1f", duration))s"
        case .authenticationFailed:
            return "Authentication failed - check username and password"
        case .radioBusy:
            return "Radio is busy (another client may be connected)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .invalidResponse:
            return "Invalid response from radio"
        case .operationCancelled:
            return "Operation was cancelled"
        case .operationInProgress(let op):
            return "Operation '\(op)' is currently in progress"
        case .invalidState(let details):
            return "Invalid state: \(details)"
        }
    }
}
