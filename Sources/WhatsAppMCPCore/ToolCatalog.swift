import Foundation
import MCP

/// The catalogue is the authorisation surface: a tool that is not listed here cannot be
/// called, and the name it is listed under is the label on the permission switch in
/// Claude Desktop.
///
/// One tool per thing this database holds — chats, messages, one message, groups,
/// attachments — rather than one per query somebody happened to need. Every tool reads, and
/// no tool carries a verb prefix because there is no verb to warn about: this server never
/// changes WhatsApp and never sends anything anywhere. Some tools also keep a result in the
/// server's own cache (see CLAUDE.md); a tool that changed WhatsApp or sent anything would
/// be the first, and must not be added.
public enum ToolCatalog {

    public static let statusName = "whatsapp_status"
    public static let chatsName = "chats_list"
    public static let chatGetName = "chat_get"
    public static let searchName = "whatsapp_search"
    public static let messageGetName = "message_get"
    public static let groupGetName = "group_get"
    public static let mediaName = "media_list"
    public static let mediaGetName = "media_get"
    public static let mediaViewName = "media_view"
    public static let audioTranscribeName = "audio_transcribe"
    public static let callsName = "calls_list"
    public static let locationSharingName = "location_sharing_list"
    public static let labelsName = "labels_list"
    public static let addressBookName = "address_book_list"
    public static let lidLookupName = "lid_lookup"
    public static let channelsName = "channels_list"
    public static let dbTablesName = "db_tables"
    public static let dbSchemaName = "db_schema"
    public static let dbQueryName = "db_query"

    public static func all() -> [Tool] {
        [status, chats, chatGet, search, messageGet, groupGet, media, mediaGet, mediaView, audioTranscribe, calls, locationSharing, labels, addressBook, lidLookup, channels, dbTables, dbSchema, dbQuery]
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
            unchanged — never from the system address book. A LID address WhatsApp has never \
            named for you stays a LID here; the chat database has no phone number for one. lid_lookup may.

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

    // MARK: Opening attachments

    static let mediaGet = Tool(
        name: mediaGetName,
        title: "Describe an attachment file",
        description: """
            Facts about the file behind one attachment: its real path under WhatsApp's \
            Message folder, MIME type, exact size, SHA-256, and the chat, sender and date \
            of the message it belongs to. Opens the file only to hash it.

            If the file is not on this Mac — WhatsApp evicts files and keeps the row — \
            it says so rather than inventing a path. Use media_list to find a message id, \
            and media_view to see what is in the file.
            """,
        inputSchema: object(
            properties: [
                "message_id": integer(
                    "Message id of the attachment, from media_list or chat_get.",
                    minimum: 1, maximum: Int.max)
            ], required: ["message_id"]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let mediaView = Tool(
        name: mediaViewName,
        title: "View an attachment",
        description: """
            Shows what is inside an attachment. A photo, sticker or GIF comes back as an \
            image, reduced to at most 1568 pixels on its longest side. A PDF (or a text \
            document) comes back as its text, capped in length; a scanned PDF has no text \
            layer and says so. A video comes back as evenly spaced still frames, and with a \
            'language' also as a transcript. A voice note or audio file is not played: \
            use audio_transcribe.

            The file must be under WhatsApp's Message folder on this Mac. If it was \
            evicted, the answer says so. The file is only read; the one thing that can be \
            written is a video's transcript, kept in this server's own cache.
            """,
        inputSchema: object(
            properties: [
                "message_id": integer(
                    "Message id of the attachment, from media_list or chat_get.",
                    minimum: 1, maximum: Int.max),
                "frames": integer(
                    "For a video: how many still frames to return.", minimum: 1, maximum: 8,
                    default: 4),
                "language": string(
                    "For a video: the language spoken, a full tag such as es-ES. Without it the "
                        + "frames come back with no transcript."),
            ], required: ["message_id"]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let audioTranscribe = Tool(
        name: audioTranscribeName,
        title: "Transcribe audio",
        description: """
            Turns a voice note, audio file or a video's sound into text, with times, using \
            the speech recognition built into macOS. It runs entirely on this Mac: nothing \
            is sent anywhere, and no language model is ever downloaded.

            Give a 'message_id' (from media_list) or a 'path' under WhatsApp's Message \
            folder — one of them — and the 'language' as a full tag (es-ES, en-US). macOS \
            cannot detect the language, so it is required, and a bare "es" or "en" is \
            refused when several regional models exist: text recognised in the wrong \
            language or accent is fluent nonsense. Basque (eu) and Catalan (ca) were not \
            in the engine's list when this was written; an unsupported language is \
            refused with the list the engine offers, never replaced by another.

            The result is an automatic transcription and can contain errors. Results are \
            kept in ~/Library/Caches/whatsapp-mcp so the same audio is recognised once. \
            On macOS 27 voice notes, MP3 and M4A open directly; a video's sound track, other \
            containers and possibly voice notes on older macOS need ffmpeg installed, and only plain audio or video containers are handed to it.
            """,
        inputSchema: object(properties: [
            "message_id": integer(
                "Message id of a voice note, audio file or video, from media_list.",
                minimum: 1, maximum: Int.max),
            "path": string("Alternatively, a file path under WhatsApp's Message folder."),
            "language": string(
                "Language spoken in the audio, a full BCP-47 tag such as es-ES or en-US."),
        ], required: ["language"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: false, idempotentHint: true,
            openWorldHint: false)
    )

    // MARK: Beyond the chat store

    private static let copyNote = """
        Read from a private copy of the database kept in ~/Library/Caches/whatsapp-mcp; the \
        answer says when it was taken.
        """

    static let calls = Tool(
        name: callsName,
        title: "List calls",
        description: """
            Lists voice and video calls from WhatsApp's call history: when, how long, \
            incoming or outgoing, missed or not, video or voice, the group if it was a \
            group call, and the participants' addresses.

            The outcome is reported as the number WhatsApp stored. Which number means \
            answered, declined or failed has not been established, and is not guessed. \
            \(copyNote)
            """,
        inputSchema: object(properties: [
            "after": afterProperty,
            "before": beforeProperty,
            "order": orderProperty,
            "limit": limitProperty,
            "offset": offsetProperty,
        ]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let locationSharing = Tool(
        name: locationSharingName,
        title: "List live-location sharing",
        description: """
            Lists live-location sharing sessions: the ones you started (chat, when, when \
            they end) and who they were shared with. Coordinates are not included — they \
            sit in a binary field this server does not decode. A location sent as an \
            ordinary message is in chat_get and media_list, with its coordinates.

            \(copyNote)
            """,
        inputSchema: object(properties: ["limit": limitProperty]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let labels = Tool(
        name: labelsName,
        title: "List labels",
        description: """
            Lists WhatsApp Business labels with their id, name, colour id and how many chats \
            or contacts carry each. With 'label_id', lists what carries that label.

            Labels exist only on accounts that use them; an empty list is normal. \
            \(copyNote)
            """,
        inputSchema: object(properties: [
            "label_id": integer(
                "Optional label id from this tool's own list. Omit to list the labels.",
                minimum: 0, maximum: Int.max),
            "limit": limitProperty,
        ]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let addressBook = Tool(
        name: addressBookName,
        title: "Search WhatsApp's address book",
        description: """
            Looks up people in WhatsApp's own copy of your address book: full, given and last \
            name, business name, phone number, LID, WhatsApp id, username and 'about' text. \
            Matching ignores case and accents.

            This is WhatsApp's own table, which can disagree with any other address book. \
            \(copyNote)
            """,
        inputSchema: object(properties: [
            "name": string("Optional text to match against names and the phone number."),
            "limit": limitProperty,
            "offset": offsetProperty,
        ]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let lidLookup = Tool(
        name: lidLookupName,
        title: "Look up a LID or phone number",
        description: """
            Given a …@lid address or a phone number, returns every pairing and name WhatsApp \
            recorded for it in its LID and extended-chat databases, each labelled with the \
            table it came from.

            No result means WhatsApp stored no pairing for that value on this Mac, not that \
            none exists. Coverage of these tables has not been measured. \(copyNote)
            """,
        inputSchema: object(
            properties: [
                "value": string("A LID (with or without @lid) or a phone number (digits).")
            ], required: ["value"]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let channels = Tool(
        name: channelsName,
        title: "List channels",
        description: """
            Lists WhatsApp channels this Mac knows about: address, name, and who added \
            it. Matching on the name ignores case and accents. \(copyNote)
            """,
        inputSchema: object(properties: [
            "name": string("Optional text to match against the channel name."),
            "limit": limitProperty,
        ]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    // MARK: Raw database access

    private static let databaseProperty: Value = .object([
        "type": .string("string"),
        "enum": .array(AllowedDatabase.allCases.map { .string($0.rawValue) }),
        "description": .string(
            "Which of WhatsApp's databases to read. A fixed list: the container also holds "
                + "encryption keys that no tool here opens."),
    ])

    private static let snapshotHelp = """
        Reads a private copy of the database made in ~/Library/Caches/whatsapp-mcp and \
        refreshed whenever WhatsApp changes the file; the answer says when the copy was \
        taken. Rows WhatsApp has not yet written out of its journal are not in the copy.
        """

    static let dbTables = Tool(
        name: dbTablesName,
        title: "List database tables",
        description: """
            Lists the tables and views in one of WhatsApp's local databases (chat store, \
            contacts, call history, labels, locations, stickers, status, channels and the \
            rest). Names only, no rows.

            Use it to see what exists before db_schema and db_query. \(snapshotHelp)
            """,
        inputSchema: object(properties: ["db": databaseProperty], required: ["db"]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true,
            openWorldHint: false)
    )

    static let dbSchema = Tool(
        name: dbSchemaName,
        title: "Read database schema",
        description: """
            Returns the CREATE statements of one database, or of one table and its \
            indexes. Structure only, no rows. The schema is WhatsApp's own and \
            undocumented, so read it rather than assuming a column name.

            \(snapshotHelp)
            """,
        inputSchema: object(
            properties: [
                "db": databaseProperty,
                "table": string("Optional table or view name from db_tables. Omit for everything."),
            ], required: ["db"]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true,
            openWorldHint: false)
    )

    static let dbQuery = Tool(
        name: dbQueryName,
        title: "Query a database",
        description: """
            Runs one SELECT (or WITH … SELECT) statement against one of WhatsApp's \
            databases and returns the rows as tab-separated text, with a blob shown as its \
            size. Anything else is refused: a second statement, ATTACH, PRAGMA, and any \
            statement that would change data. Rows are capped and a long-running statement \
            is stopped.

            This is the escape hatch for what the dedicated tools do not cover. Prefer \
            chats_list, chat_get and media_list for ordinary reading, and call db_schema \
            first — column names are WhatsApp's and change between versions. \(snapshotHelp)
            """,
        inputSchema: object(
            properties: [
                "db": databaseProperty,
                "sql": string("A single SELECT or WITH … SELECT statement."),
                "limit": integer(
                    "Maximum rows to return.", minimum: SnapshotDatabaseExplorer.rowLimitRange.lowerBound,
                    maximum: SnapshotDatabaseExplorer.rowLimitRange.upperBound,
                    default: SnapshotDatabaseExplorer.defaultRowLimit),
            ], required: ["db", "sql"]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true,
            openWorldHint: false)
    )

}
