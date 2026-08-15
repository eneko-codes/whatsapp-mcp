import Foundation
import MCP

/// The catalogue is the authorisation surface: a tool that is not listed here cannot be
/// called, and the name it is listed under is the label on the permission switch in
/// Claude Desktop.
///
/// One tool per thing this database holds — chats, messages, one message, groups,
/// attachments — rather than one per query somebody happened to need. Every tool here is a
/// read, and no tool carries a verb prefix because there is no verb to warn about: this
/// server never writes to WhatsApp's database and never sends anything anywhere. A tool
/// that did either would be the first, and must not be added.
public enum ToolCatalog {

    public static let statusName = "whatsapp_status"
    public static let chatsName = "chats_list"
    public static let chatGetName = "chat_get"
    public static let searchName = "whatsapp_search"
    public static let messageGetName = "message_get"
    public static let groupGetName = "group_get"
    public static let mediaName = "media_list"

    public static func all() -> [Tool] {
        [status, chats, chatGet, search, messageGet, groupGet, media]
    }

    // MARK: Schema helpers

    private static func object(properties: [String: Value], required: [String] = []) -> Value {
        var schema: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        schema["additionalProperties"] = .bool(false)
        return .object(schema)
    }

    /// Every `type` here is a single string, never `["string", "null"]`. Claude Desktop's
    /// schema sanitiser drops a property outright when its `type` is a union and hands
    /// the model a bare `{}` in its place; an array argument is then serialised to a
    /// string and rejected on arrival. `schemasDeclareScalarTypes` walks the whole
    /// catalogue and fails if one ever creeps back in.
    private static func string(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func boolean(_ description: String) -> Value {
        .object(["type": .string("boolean"), "description": .string(description)])
    }

    /// `default` is omitted unless one is given, because a declared default is a value the
    /// client may materialise. On a field whose description says "omit for every chat",
    /// declaring `default: 1` quietly scopes every call to chat 1 — the schema and the
    /// description would be saying opposite things, and the schema wins.
    private static func integer(
        _ description: String, minimum: Int, maximum: Int, default def: Int? = nil
    ) -> Value {
        var schema: [String: Value] = [
            "type": .string("integer"), "description": .string(description),
            "minimum": .int(minimum), "maximum": .int(maximum),
        ]
        if let def { schema["default"] = .int(def) }
        return .object(schema)
    }

    private static func stringArray(_ description: String) -> Value {
        .object([
            "type": .string("array"),
            "items": .object(["type": .string("string")]),
            "description": .string(description),
        ])
    }

    private static let dateHelp = """
        Accepts 2026-08-12 (midnight local time), 2026-08-12T09:00 (local time), or \
        2026-08-12T09:00:00+02:00 (explicit offset).
        """

    private static let limitProperty: Value = integer(
        "Maximum rows to return.", minimum: Configuration.pageSizeRange.lowerBound,
        maximum: Configuration.pageSizeRange.upperBound, default: Configuration.pageSize)

    private static let offsetProperty: Value = integer(
        "Skip this many matches; use it to page.",
        minimum: Configuration.offsetRange.lowerBound,
        maximum: Configuration.offsetRange.upperBound, default: 0)

    private static let orderProperty: Value = .object([
        "type": .string("string"),
        "enum": .array([.string("newest"), .string("oldest")]),
        "default": .string("newest"),
        "description": .string(
            "Sort direction by date. Defaults to newest first, which is how a conversation is read."
        ),
    ])

    private static let afterProperty: Value = string(
        "Only messages at or after this moment. \(dateHelp)")
    private static let beforeProperty: Value = string(
        "Only messages strictly before this moment — the bound is exclusive, so two "
            + "adjacent ranges neither overlap nor drop a message. \(dateHelp)")

    private static let mediaKindList = MediaKind.allCases.map(\.rawValue).joined(separator: ", ")

    // MARK: Reads

    static let status = Tool(
        name: statusName,
        title: "WhatsApp reachability",
        description: """
            Reports whether WhatsApp's local database can be read, how much is in it, \
            what WhatsApp does not store locally at all, and exactly what to do about \
            anything missing. Reads no messages.

            Call it first when setting up, and whenever another tool fails. Do not use it \
            to look for messages.
            """,
        inputSchema: object(properties: [:]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let chats = Tool(
        name: chatsName,
        title: "List chats",
        description: """
            Lists conversations with their id, kind, unread count, how many messages \
            are stored, and when the last one arrived.

            Start here. Every other read tool takes a chat id from this list, and the \
            ids are row numbers in a local database — they cannot be guessed or \
            reconstructed. Archived and hidden chats are left out unless you ask for them.
            """,
        inputSchema: object(properties: [
            "name": string("Optional text to match against the chat name. Ignores case and accents."),
            "kinds": stringArray(
                "Optional kinds to include: "
                    + ChatKind.allCases.filter { $0 != .unknown }.map(\.rawValue)
                    .joined(separator: ", ")
                    + ". Omit for all of them."),
            "include_archived": boolean("Include archived chats. Defaults to false."),
            "include_hidden": boolean(
                "Include chats WhatsApp flags as hidden. Defaults to false. What WhatsApp's "
                    + "own interface calls this state is not established — the flag is "
                    + "reported as it is stored."),
            "limit": limitProperty,
            "offset": offsetProperty,
        ]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true,
            openWorldHint: false)
    )

    static let chatGet = Tool(
        name: chatGetName,
        title: "Read one chat",
        description: """
            Returns a page of messages from one chat, newest first by default. Each line \
            carries the message id, its timestamp, who sent it, and what the message \
            actually is — text, a photo, a voice note with its length, a sticker, a \
            shared location with its coordinates, a link with its preview, a group event, \
            or a message deleted for everyone.

            Paged, always: a chat can hold tens of thousands of messages. The header \
            says how many matched, so 'offset' can walk back through the history. \
            Narrow with 'after'/'before' rather than paging blindly. Use message_get on \
            an id from the first column for everything about a single message.
            """,
        inputSchema: object(
            properties: [
                "chat_id": integer(
                    "Chat id from chats_list.", minimum: 1, maximum: Int.max),
                "after": afterProperty,
                "before": beforeProperty,
                "from_me": boolean(
                    "true for only your own messages, false for only theirs. Omit for both."),
                "starred_only": boolean("Only messages starred in WhatsApp. Defaults to false."),
                "order": orderProperty,
                "limit": limitProperty,
                "offset": offsetProperty,
            ],
            required: ["chat_id"]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true,
            openWorldHint: false)
    )

    static let search = Tool(
        name: searchName,
        title: "Search messages",
        description: """
            Finds messages whose text contains a phrase, across every chat or within \
            one. Matching ignores case and accents, so "angel" finds "Ángel". Results \
            are laid out exactly as chat_get lays them out, with the chat named on each \
            line.

            Searches text only. A photo, sticker or voice note with no caption has no \
            text to match, so use media_list for those.
            """,
        inputSchema: object(
            properties: [
                "query": string("Text to find inside a message."),
                "chat_id": integer(
                    "Optional chat id from chats_list. Omit to search every chat.",
                    minimum: 1, maximum: Int.max),
                "after": afterProperty,
                "before": beforeProperty,
                "from_me": boolean(
                    "true for only your own messages, false for only theirs. Omit for both."),
                "starred_only": boolean("Only messages starred in WhatsApp. Defaults to false."),
                "order": orderProperty,
                "limit": limitProperty,
                "offset": offsetProperty,
            ],
            required: ["query"]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true,
            openWorldHint: false)
    )

    static let messageGet = Tool(
        name: messageGetName,
        title: "Read one message",
        description: """
            Everything this database holds about a single message: its text with every \
            mention resolved and listed, who sent it and their WhatsApp address, both \
            timestamps, whether it is starred, an attachment's file path, size, length, \
            author and WhatsApp server URL, a shared contact's full vCard, a link \
            preview's title and summary, a group event's actor and subject, and the raw \
            delivery and error codes.

            Use it when a line from chat_get or whatsapp_search needs opening up. The \
            delivery code is reported as the number WhatsApp stored: this server has not \
            established which code means sent, delivered or read, and will not guess.
            """,
        inputSchema: object(
            properties: [
                "message_id": integer(
                    "Message id — the first column of a chat_get, whatsapp_search or "
                        + "media_list line.", minimum: 1, maximum: Int.max)
            ],
            required: ["message_id"]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true,
            openWorldHint: false)
    )

    static let media = Tool(
        name: mediaName,
        title: "List attachments",
        description: """
            Lists what was shared rather than said: photos, videos, GIFs, stickers, \
            voice notes, audio files, documents, shared locations and shared contact \
            cards, with the message id each belongs to and the file's path on this Mac \
            when it is here.

            Voice notes and audio files are separate kinds, because WhatsApp stores them \
            as the same type and only one column tells them apart. A location comes with \
            its coordinates and a contact card with the name on it, since for those two \
            there is no file — that is the whole content of the message.

            A path may be missing: WhatsApp does not keep every file locally forever, \
            and an absent path means the file is not on this Mac, not that the message \
            is gone. This tool lists; it never opens a file.
            """,
        inputSchema: object(properties: [
            "chat_id": integer(
                "Optional chat id from chats_list. Omit for every chat.",
                minimum: 1, maximum: Int.max),
            "kinds": stringArray(
                "Optional kinds to include: \(mediaKindList). Omit for all of them."),
            "after": afterProperty,
            "before": beforeProperty,
            "from_me": boolean(
                "true for only your own attachments, false for only theirs. Omit for both."),
            "order": orderProperty,
            "limit": limitProperty,
            "offset": offsetProperty,
        ]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true,
            openWorldHint: false)
    )

    static let groupGet = Tool(
        name: groupGetName,
        title: "Read one group",
        description: """
            What this server can read about a group itself: when it was created and by \
            whom, when its name was last changed and by whom, and every member row with \
            its WhatsApp address, resolved name and admin flag.

            The member table is not a snapshot of who is in the group today. It keeps \
            rows flagged inactive — 86 of 190 across the measured library — so somebody \
            who has left most likely still appears, marked inactive. What inactive means \
            exactly is not stated by the database and is not guessed here.

            Names are resolved the same way as elsewhere: WhatsApp's own profile name \
            first, a phone number for a plain phone address, otherwise the address \
            unchanged — never through Apple Contacts. A LID address WhatsApp has never \
            named for you stays a LID; this server has no phone number to offer for one.

            Only works on group chats — call chats_list with kinds: ["group"] to find \
            one.
            """,
        inputSchema: object(
            properties: [
                "chat_id": integer(
                    "Group chat id from chats_list.", minimum: 1, maximum: Int.max)
            ],
            required: ["chat_id"]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true,
            openWorldHint: false)
    )

}
