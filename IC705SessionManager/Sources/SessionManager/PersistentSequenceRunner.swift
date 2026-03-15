import Foundation

public enum PersistentSequenceRunner {
    public static func run(
        config: ConnectionConfig,
        cwText: String,
        stageHandler: (@Sendable (String) -> Void)? = nil
    ) async throws -> SequenceResult {
        let session = PersistentRadioSession(config: config)
        session.stageHandler = stageHandler

        let connection = try await session.connect()
        do {
            let speed = try await session.queryCWSpeed()
            let status = try await session.queryStatus()
            let cwSent = try await session.sendCW(cwText)
            await session.disconnect()

            return SequenceResult(
                radioName: connection.radioName,
                cwSpeedWPM: speed,
                frequencyHz: status.frequencyHz,
                mode: status.mode,
                cwSent: cwSent
            )
        } catch {
            await session.disconnect()
            throw error
        }
    }
}
