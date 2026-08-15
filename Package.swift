// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "whatsapp-mcp",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1")
    ],
    targets: [
        // All logic lives here so the tests can import it. The executable target below
        // is only a launcher: an executable target cannot be imported by a test target.
        //
        // SQLite comes from the system module macOS already ships. Reading the chat
        // store needs a database driver, and adding a package for it would mean auditing
        // a dependency to do what `import SQLite3` does in one line.
        //
        // No Objective-C target and no embedded Info.plist: both existed only for the
        // Apple event that drove the Shortcuts send path. This server reads a file and
        // does nothing else, so it needs no TCC identity at all.
        .target(
            name: "WhatsAppMCPCore",
            dependencies: [.product(name: "MCP", package: "swift-sdk")]
        ),
        .executableTarget(name: "whatsapp-mcp", dependencies: ["WhatsAppMCPCore"]),
        .testTarget(name: "WhatsAppMCPCoreTests", dependencies: ["WhatsAppMCPCore"]),
    ]
)
