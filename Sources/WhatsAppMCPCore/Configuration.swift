import Foundation

/// There is nothing to configure. The per-tool allow/ask/prohibit switch in Claude
/// Desktop is the whole of this server's configuration surface.
///
/// `--database` is the one flag parsed from the command line, and it is not a
/// `user_config` setting at all — nothing in `extension/manifest.json` sets it. It exists
/// for `verification.md`, so a manual run can be pointed at a copy of the database
/// instead of the live file.
public struct Configuration: Sendable, Equatable {
    /// Default page size for `chats_list`, `chat_get`, `whatsapp_search` and `media_list`.
    /// A tool's own `limit` still wins.
    public static let pageSize = 50

    /// Where the chat store lives. Overridable only from the command line — see
    /// `verification.md` — without the live file ever being opened.
    public var databasePath: String = Configuration.defaultDatabasePath

    public init() {}

    /// WhatsApp's group container. Not TCC-protected, unlike `~/Library/Messages`, which
    /// is what makes the whole read path possible with no grant and no prompt.
    public static var defaultDatabasePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite"
            )
            .path
    }

    public static let pageSizeRange = 1...200

    /// Paging ceiling. Declared here so the advertised schema and the enforced clamp
    /// cannot drift: both read this one value.
    public static let offsetRange = 0...100_000

    /// True when an argument is an unsubstituted manifest placeholder. Kept for
    /// `--database`, the one remaining flag: Claude Desktop leaves `${user_config.key}`
    /// untouched when a setting is empty, and this server has been bitten by that once
    /// already (observed live on the calendar server).
    static func isPlaceholder(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("${") && trimmed.hasSuffix("}")
    }

    /// Unknown flags are ignored rather than fatal. A server that will not launch is much
    /// harder to diagnose than one running on its default.
    public static func parse(_ arguments: [String]) -> Configuration {
        var configuration = Configuration()
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            let value = index + 1 < arguments.count ? arguments[index + 1] : nil

            switch flag {
            case "--database":
                if let value, !isPlaceholder(value) {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        configuration.databasePath = (trimmed as NSString).expandingTildeInPath
                    }
                }
                index += 2

            default:
                index += 1
            }
        }
        return configuration
    }
}
