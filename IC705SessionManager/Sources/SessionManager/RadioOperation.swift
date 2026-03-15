import Foundation

public struct ConnectionConfig: Equatable, Codable {
    public let host: String
    public let username: String
    public let password: String
    public let computerName: String

    public init(host: String, username: String, password: String, computerName: String = "CLI") {
        self.host = host
        self.username = username
        self.password = password
        self.computerName = computerName
    }
}

public struct ConnectionResult: Equatable, Encodable {
    public let radioName: String
    public let remoteCIVPort: UInt16

    public init(radioName: String, remoteCIVPort: UInt16) {
        self.radioName = radioName
        self.remoteCIVPort = remoteCIVPort
    }
}

public struct StatusResult: Equatable, Encodable {
    public let frequencyHz: Int
    public let mode: String
    public let isConnected: Bool

    public init(frequencyHz: Int, mode: String, isConnected: Bool) {
        self.frequencyHz = frequencyHz
        self.mode = mode
        self.isConnected = isConnected
    }
}

public struct SequenceResult: Equatable, Encodable {
    public let radioName: String
    public let cwSpeedWPM: Int
    public let frequencyHz: Int
    public let mode: String
    public let cwSent: Bool

    public init(
        radioName: String,
        cwSpeedWPM: Int,
        frequencyHz: Int,
        mode: String,
        cwSent: Bool
    ) {
        self.radioName = radioName
        self.cwSpeedWPM = cwSpeedWPM
        self.frequencyHz = frequencyHz
        self.mode = mode
        self.cwSent = cwSent
    }
}
