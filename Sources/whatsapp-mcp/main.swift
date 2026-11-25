import Foundation
import WhatsAppMCPCore

// Launcher only. Everything testable lives in WhatsAppMCPCore, which the test target
// imports; an executable target cannot be imported.
//
// Settings come from the Claude extension manifest, which substitutes the
// person's user_config into this process's arguments.
await WhatsAppMCPServer.run(
    configuration: Configuration.parse(Array(CommandLine.arguments.dropFirst())))
