import Foundation

/// Reading needs no configuration. The per-tool allow/ask/prohibit switch in Claude
/// Desktop is the whole of this server's configuration surface.
///
/// `--database`, `--scratch-directory` and `--ffmpeg` are the flags parsed from the command
/// line, and none is a `user_config` setting — nothing in `extension/manifest.json` sets
/// them. The first two exist for manual verification, so a run can be pointed at a copy of
/// the container and at a throwaway scratch directory instead of the live ones; `--ffmpeg` names the
/// converter when it is not in one of Homebrew's two prefixes.
public struct Configuration: Sendable, Equatable {

    // MARK: Pages
    //
    // Each maximum is a number of rows of ordinary width that fits
    // `ToolStandard.longestResult` with room to spare, and each default makes a call with no
    // optional argument about `ToolStandard.usualPage` or less. `BoundsTests` renders a full
    // page of the widest ordinary rows of every listing to hold both to that. The schemas,
    // the descriptions and the instructions quote these values; none repeats a figure.

    /// Rows a listing may skip. One range for every tool that pages.
    public static let offsetRange = 0...10_000_000

    /// A row id. The upper end is the largest whole number every JSON client carries
    /// exactly. A value outside the range is refused, never moved: the nearest id would be
    /// another chat or message than the one asked for.
    public static let identifierRange = 1...9_007_199_254_740_991
    /// WhatsApp numbers its own labels from zero.
    public static let labelIdentifierRange = 0...9_007_199_254_740_991

    /// Chats, group members, calls, live-location rows, labels, address-book entries,
    /// LID records and channels: short rows of names, addresses and dates.
    public static let limitRange = 1...200
    public static let defaultLimit = 50

    /// `chat_get`, `whatsapp_search` and `media_list`, whose rows carry a message's text.
    public static let messageLimitRange = 1...100
    public static let defaultMessageLimit = 30

    /// `db_tables`: a name and a kind per row.
    public static let tableLimitRange = 1...500
    public static let defaultTableLimit = 200

    /// `db_schema`: one CREATE statement per row, a few hundred characters each and a few
    /// thousand for WhatsApp's widest tables.
    public static let schemaLimitRange = 1...50
    public static let defaultSchemaLimit = 10

    /// `db_query`: rows of a statement nobody here wrote, so of any width. Reading stops at
    /// `queryCharacters` with no `limit` given and at `longestQueryCharacters` with one, so a
    /// call with no optional argument is about one usual page however wide the rows are.
    public static let queryLimitRange = 1...200
    public static let defaultQueryLimit = 50
    public static let queryCharacters = ToolStandard.usualPage
    public static let longestQueryCharacters = ToolStandard.longestResult / 2

    // MARK: Widths

    /// How much of a message's text (or a caption) a row shows.
    public static let textWidth = 160
    /// How much of an attachment's file name and of a link preview's title a row shows.
    public static let titleWidth = 80
    /// How much of a link's address a row shows.
    public static let linkWidth = 160
    /// How many reaction emoji a row shows.
    public static let reactionsWidth = 24
    /// How much of a call's participant list a row shows.
    public static let participantsWidth = 200
    /// How much of one value a `db_query` row shows.
    public static let cellWidth = 500
    /// How much of another program's text (SQLite, ffmpeg) an error repeats.
    public static let errorDetailWidth = 1_000

    // MARK: Windows

    /// The window on one long text: a message, a document, a transcript. The maximum is
    /// half the longest result, so a window of ordinary text leaves room for the heading
    /// around it; `ToolStandard.fitting` shrinks one whose characters take more UTF-16
    /// units than that.
    public static let maxCharactersRange = 1...(ToolStandard.longestResult / 2)
    public static let defaultMaxCharacters = ToolStandard.usualPage

    /// Pages of a PDF, numbered from one.
    public static let pageNumberRange = 1...1_000_000

    /// Still frames of one video. A video is several moments, so `media_view` is the one
    /// tool that returns more than one image, and never more than this.
    public static let frameRange = 1...8
    public static let defaultFrames = 4

    // MARK: Time

    /// The longest a call may run before it is abandoned. Transcribing a long recording is
    /// the slowest thing any tool does, so this sits close to `ToolStandard.timeLimit`
    /// while leaving room for the answer to travel.
    public static let callTimeout = Duration.seconds(180)

    /// Where the chat store lives. Overridable only from the command line, so a manual
    /// run can be pointed elsewhere without the live file ever being opened.
    public var databasePath: String = Configuration.defaultDatabasePath

    /// Where the scratch folder for audio conversion is made — the only place this server
    /// writes, and nothing stays there between calls. Overridable from the command line so a
    /// manual run or a test never touches the real one.
    public var scratchDirectory: String = ContainerDatabases.defaultScratchDirectory.path

    /// The `ffmpeg` that converts what macOS cannot open itself: a video's sound track and
    /// containers like Matroska.
    /// Nil means "look in Homebrew's two prefixes"; a path given here is used as it is.
    public var ffmpegPath: String?

    public init() {}

    /// WhatsApp's container is the directory the chat database sits in, so pointing
    /// `--database` at a copy moves every `db_*` read to that copy's directory as well.
    public var containerDirectory: URL {
        URL(fileURLWithPath: databasePath).deletingLastPathComponent()
    }

    /// WhatsApp's group container. On recent macOS another app's data needs Full Disk Access
    /// for the program that opens it; without that grant the file can be seen but not read,
    /// which `SystemWhatsAppStore.availability()` reports as `.accessDenied`.
    public static var defaultDatabasePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite"
            )
            .path
    }

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

            case "--ffmpeg":
                if let value, !isPlaceholder(value) {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        configuration.ffmpegPath = (trimmed as NSString).expandingTildeInPath
                    }
                }
                index += 2

            case "--scratch-directory":
                if let value, !isPlaceholder(value) {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        configuration.scratchDirectory = (trimmed as NSString).expandingTildeInPath
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
