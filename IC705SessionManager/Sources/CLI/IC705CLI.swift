import ArgumentParser
import Foundation
import SessionManager

@main
struct IC705CLI: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "ic705-cli",
        abstract: "CLI tool for controlling Icom IC-705 radios",
        discussion: """
        Connect to and control an IC-705 radio via the RS-BA1 protocol.

        Examples:
          ic705-cli connect --host 192.168.2.144 --user ADMIN --pass secret
          ic705-cli status
          ic705-cli send-cw "CQ CQ DE W1AW K"
          ic705-cli disconnect
        """,
        version: "1.0.0",
        subcommands: [ConnectCommand.self, StatusCommand.self, SendCWCommand.self, DisconnectCommand.self, WatchCommand.self],
        defaultSubcommand: StatusCommand.self
    )
}
