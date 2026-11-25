import Foundation

/// The catalogue is the authorisation surface: a tool that is not listed here cannot be
/// called, and the name it is listed under is the label on the permission switch in
/// Claude Desktop.
///
/// One tool per thing this database holds — chats, messages, one message, groups,
/// attachments — rather than one per query somebody happened to need. Every tool reads, and
/// no tool carries a verb prefix because there is no verb to warn about: this server never
/// changes WhatsApp and never sends anything anywhere, and keeps nothing: the only file any
/// tool makes is a scratch directory for audio conversion, deleted when the call ends (see
/// CLAUDE.md). A tool that changed WhatsApp, sent anything or stored a result would be the
/// first, and must not be added.
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
        Accepts 2026-08-12 (a whole day), 2026-08-12T09:00 (local time), or \
        2026-08-12T09:00:00+02:00 (explicit offset).
        """

    /// An id: its range is stated so a client can refuse what the server would refuse.
    private static func identifier(
        _ description: String, range: ClosedRange<Int> = Configuration.identifierRange
    ) -> Value {
        integer(description, minimum: range.lowerBound, maximum: range.upperBound)
    }

    private static func limit(_ things: String, range: ClosedRange<Int>, default def: Int) -> Value {
        integer(
            "Maximum number of \(things) in one page.", minimum: range.lowerBound,
            maximum: range.upperBound, default: def)
    }

    private static let offset: Value = integer(
        """
        Number of rows to skip. A result that does not hold every row says, in its first \
        lines, the offset to pass for the next page.
        """, minimum: Configuration.offsetRange.lowerBound,
        maximum: Configuration.offsetRange.upperBound, default: 0)

    private static let characterOffset: Value = integer(
        """
        Number of characters to skip. A result that does not hold the whole text says, in \
        its first lines, the character_offset to pass for the rest.
        """, minimum: Configuration.offsetRange.lowerBound,
        maximum: Configuration.offsetRange.upperBound, default: 0)

    private static let maxCharacters: Value = integer(
        "Maximum number of characters of the text in one window.",
        minimum: Configuration.maxCharactersRange.lowerBound,
        maximum: Configuration.maxCharactersRange.upperBound,
        default: Configuration.defaultMaxCharacters)

    private static let orderProperty: Value = .object([
        "type": .string("string"),
        "enum": .array([.string("newest"), .string("oldest")]),
        "default": .string("newest"),
        "description": .string(
            "Sort direction by date, ties by id. Defaults to newest first, which is how a conversation is read."
        ),
    ])

    private static let fromDate: Value = string(
        "Only from this moment on, inclusive. Alone, it runs to the newest. \(dateHelp)")
    private static let toDate: Value = string(
        "Only up to this moment, inclusive at the precision written: a day includes the whole "
            + "day, a minute the whole minute. Alone, it runs from the oldest. \(dateHelp)")

    private static let mediaKindList = MediaKind.allCases.map(\.rawValue).joined(separator: ", ")

    private static let readOnly = Tool.Annotations(
        readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)

    /// How a listing's description says what one call returns and how to get the rest.
    private static func paging(_ things: String, _ range: ClosedRange<Int>, _ def: Int) -> String {
        """
        \(def) \(things) to a page by default. When more match, the first lines of the \
        result say how many and the offset of the next page: pass limit (up to \
        \(range.upperBound)) and offset for the rest.
        """
    }

    private static let messagePaging = """
        \(Configuration.defaultMessageLimit) messages to a page by default, and a message's \
        text is clipped to \(Configuration.textWidth) characters in each row; the first \
        lines of the result say when either happened. Pass limit (up to \
        \(Configuration.messageLimitRange.upperBound)) and offset for more rows, and read one \
        message whole with message_get.
        """

    private static let windowHelp = """
        at most \(Configuration.defaultMaxCharacters) characters of the text by default; the \
        first lines of the result say when there is more and the character_offset that \
        continues. Pass character_offset and max_characters (up to \
        \(Configuration.maxCharactersRange.upperBound)) for the rest.
        """

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
        annotations: readOnly)

    static let chats = Tool(
        name: chatsName,
        title: "List chats",
        description: """
            Lists conversations, latest activity first (pinned chats on top, as in \
            WhatsApp), with their id, kind, unread count, how many messages are stored, and \
            when the last one arrived. Archived and hidden chats are left out unless \
            include_archived or include_hidden is set; the result says how many were left out.

            \(paging("chats", Configuration.limitRange, Configuration.defaultLimit))

            Start here. Every other read tool takes a chat id from this list, and the ids \
            are row numbers in a local database — they cannot be guessed or reconstructed.
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
            "limit": limit("chats", range: Configuration.limitRange, default: Configuration.defaultLimit),
            "offset": offset,
        ]),
        annotations: readOnly)

    static let chatGet = Tool(
        name: chatGetName,
        title: "Read one chat",
        description: """
            Returns a page of messages from one chat, newest first by default. Each line \
            carries the message id, its timestamp, who sent it, and what the message \
            actually is — text, a photo, a voice note with its length, a sticker, a \
            shared location with its coordinates, a link with its preview, a group event, \
            or a message deleted for everyone.

            \(messagePaging) Narrow with from_date and to_date rather than paging blindly \
            through a chat of tens of thousands of messages.
            """,
        inputSchema: object(
            properties: [
                "chat_id": identifier("Chat id from chats_list."),
                "from_date": fromDate,
                "to_date": toDate,
                "from_me": boolean(
                    "true for only your own messages, false for only theirs. Omit for both."),
                "starred_only": boolean("Only messages starred in WhatsApp. Defaults to false."),
                "order": orderProperty,
                "limit": limit(
                    "messages", range: Configuration.messageLimitRange,
                    default: Configuration.defaultMessageLimit),
                "offset": offset,
            ],
            required: ["chat_id"]),
        annotations: readOnly)

    static let search = Tool(
        name: searchName,
        title: "Search messages",
        description: """
            Finds messages whose text contains a phrase, across every chat or within \
            one, newest first by default. Matching ignores case and accents, so "angel" \
            finds "Ángel". Results are laid out as chat_get lays them out, with the chat \
            named on each line.

            \(messagePaging)

            Searches text only. A photo, sticker or voice note with no caption has no \
            text to match, so use media_list for those. With starred_only=true the phrase \
            can be left out, which lists every starred message in every chat. WhatsApp \
            stores only that a message is starred: not who starred it and not when.
            """,
        inputSchema: object(
            properties: [
                "query": string(
                    "Text to find inside a message. May be omitted only with starred_only=true."),
                "chat_id": identifier("Optional chat id from chats_list. Omit to search every chat."),
                "from_date": fromDate,
                "to_date": toDate,
                "from_me": boolean(
                    "true for only your own messages, false for only theirs. Omit for both."),
                "starred_only": boolean("Only messages starred in WhatsApp. Defaults to false."),
                "order": orderProperty,
                "limit": limit(
                    "messages", range: Configuration.messageLimitRange,
                    default: Configuration.defaultMessageLimit),
                "offset": offset,
            ],
            required: []),
        annotations: readOnly)

    static let messageGet = Tool(
        name: messageGetName,
        title: "Read one message",
        description: """
            Everything this database holds about a single message, whole: its text with \
            every mention resolved and listed, who sent it and their WhatsApp address, both \
            timestamps, whether it is starred, an attachment's file path, size, length, \
            author and WhatsApp server URL, a shared contact's full vCard, a link \
            preview's title and summary, a group event's actor and subject, the message \
            it replies to (with the quoted words), who reacted with which emoji and when, \
            and the raw delivery and error codes.

            It comes \(windowHelp)

            Use it when a line from chat_get, whatsapp_search or media_list was clipped or \
            needs opening up. The delivery code is reported as the number WhatsApp \
            stored: which code means sent, delivered or read is not established.
            """,
        inputSchema: object(
            properties: [
                "message_id": identifier(
                    "Message id — the first column of a chat_get, whatsapp_search or media_list line."),
                "character_offset": characterOffset,
                "max_characters": maxCharacters,
            ],
            required: ["message_id"]),
        annotations: readOnly)

    static let media = Tool(
        name: mediaName,
        title: "List attachments",
        description: """
            Lists what was shared rather than said, newest first by default: photos, \
            videos, GIFs, stickers, voice notes, audio files, documents, shared locations \
            and shared contact cards, with the message id each belongs to and the file's \
            path on this Mac when it is here.

            \(messagePaging)

            Voice notes and audio files are separate kinds, because WhatsApp stores them \
            as the same type and only one column tells them apart. A location comes with \
            its coordinates and a contact card with the name on it. A path may be missing: \
            WhatsApp does not keep every file locally forever, and an absent path means the \
            file is not on this Mac, not that the message is gone. This tool never opens a file.
            """,
        inputSchema: object(properties: [
            "chat_id": identifier("Optional chat id from chats_list. Omit for every chat."),
            "kinds": stringArray(
                "Optional kinds to include: \(mediaKindList). Omit for all of them."),
            "from_date": fromDate,
            "to_date": toDate,
            "from_me": boolean(
                "true for only your own attachments, false for only theirs. Omit for both."),
            "order": orderProperty,
            "limit": limit(
                "attachments", range: Configuration.messageLimitRange,
                default: Configuration.defaultMessageLimit),
            "offset": offset,
        ]),
        annotations: readOnly)

    static let groupGet = Tool(
        name: groupGetName,
        title: "Read one group",
        description: """
            What this server can read about a group itself: when it was created and by \
            whom, when its name was last changed and by whom, and its member rows by \
            address, each with its WhatsApp address, resolved name and admin flag.

            \(paging("members", Configuration.limitRange, Configuration.defaultLimit))

            The member table is not a snapshot of who is in the group today. It keeps \
            rows flagged inactive, so somebody who has left most likely still appears, \
            marked inactive. What inactive means exactly is not stated by the database and \
            is not guessed here. Names are WhatsApp's own profile name first, a phone \
            number for a plain phone address, otherwise the address unchanged — never \
            from the system address book. A LID address WhatsApp has never named for you \
            stays a LID here; lid_lookup may pair it with a phone number.

            Only works on group chats — call chats_list with kinds: ["group"] to find one.
            """,
        inputSchema: object(
            properties: [
                "chat_id": identifier("Group chat id from chats_list."),
                "limit": limit("members", range: Configuration.limitRange, default: Configuration.defaultLimit),
                "offset": offset,
            ],
            required: ["chat_id"]),
        annotations: readOnly)

    // MARK: Opening attachments

    static let mediaGet = Tool(
        name: mediaGetName,
        title: "Describe an attachment file",
        description: """
            Facts about the file behind one attachment: its real path under WhatsApp's \
            Message folder, MIME type, exact size, SHA-256, and the chat, sender and date \
            of the message it belongs to, with its caption clipped to \
            \(Configuration.textWidth) characters (message_get has it whole). Opens the file \
            only to hash it.

            If the file is not on this Mac — WhatsApp evicts files and keeps the row — \
            it says so rather than inventing a path. Use media_list to find a message id, \
            and media_view to see what is in the file.
            """,
        inputSchema: object(
            properties: [
                "message_id": identifier("Message id of the attachment, from media_list or chat_get.")
            ], required: ["message_id"]),
        annotations: readOnly)

    static let mediaView = Tool(
        name: mediaViewName,
        title: "View an attachment",
        description: """
            Shows what is inside an attachment. A photo, sticker or GIF comes back as one \
            image, reduced to at most \(MediaFiles.maximumImageSide) pixels on its longest \
            side. A video comes back as \(Configuration.defaultFrames) evenly spaced still \
            frames by default (frames, up to \(Configuration.frameRange.upperBound)), and with \
            a 'language' also as a transcript. A PDF or a text document comes back as its \
            text; a scanned PDF has no text layer and says so. A voice note or audio file is \
            not played: use audio_transcribe.

            The text of a document or of a video's transcript: \(windowHelp) For a PDF, \
            first_page and last_page (numbered from one, both included) choose the pages read; \
            the default is every page.

            The file must be under WhatsApp's Message folder on this Mac. If it was \
            evicted, the answer says so. The file is only read, and nothing is kept.
            """,
        inputSchema: object(
            properties: [
                "message_id": identifier("Message id of the attachment, from media_list or chat_get."),
                "frames": integer(
                    "For a video: how many still frames to return.",
                    minimum: Configuration.frameRange.lowerBound,
                    maximum: Configuration.frameRange.upperBound, default: Configuration.defaultFrames),
                "language": string(
                    "For a video: the language spoken, a full tag such as es-ES. Without it the "
                        + "frames come back with no transcript."),
                "first_page": integer(
                    "For a PDF: the first page to read, numbered from one.",
                    minimum: Configuration.pageNumberRange.lowerBound,
                    maximum: Configuration.pageNumberRange.upperBound, default: 1),
                "last_page": integer(
                    "For a PDF: the last page to read, included. Past the end means the last page. "
                        + "Omit for every page from first_page on.",
                    minimum: Configuration.pageNumberRange.lowerBound,
                    maximum: Configuration.pageNumberRange.upperBound),
                "character_offset": characterOffset,
                "max_characters": maxCharacters,
            ], required: ["message_id"]),
        annotations: readOnly)

    static let audioTranscribe = Tool(
        name: audioTranscribeName,
        title: "Transcribe audio",
        description: """
            Turns a voice note, audio file or a video's sound into text, one timed line per \
            segment, using the speech recognition built into macOS. It runs entirely on \
            this Mac: nothing is sent anywhere, and no language model is ever downloaded.

            The transcript comes \(windowHelp) Nothing is stored, so every call recognises the whole recording \
            again, a later window included. A recording too long to recognise within \
            \(Int(Configuration.callTimeout.components.seconds)) seconds cannot be transcribed here.

            Give a 'message_id' (from media_list) or a 'path' under WhatsApp's Message \
            folder — one of them — and the 'language' as a full tag (es-ES, en-US). macOS \
            cannot detect the language, so it is required, and a bare "es" or "en" is \
            refused when several regional models exist: text recognised in the wrong \
            language or accent is fluent nonsense. Basque (eu) and Catalan (ca) were not \
            in the engine's list when this was written; an unsupported language is \
            refused with the list the engine offers, never replaced by another.

            The result is an automatic transcription and can contain errors. On macOS 27 \
            voice notes, MP3 and M4A open directly; a video's sound track, other containers \
            and possibly voice notes on older macOS need ffmpeg installed, and only plain \
            audio or video containers are handed to it.
            """,
        inputSchema: object(properties: [
            "message_id": identifier("Message id of a voice note, audio file or video, from media_list."),
            "path": string("Alternatively, a file path under WhatsApp's Message folder."),
            "language": string(
                "Language spoken in the audio, a full BCP-47 tag such as es-ES or en-US."),
            "character_offset": characterOffset,
            "max_characters": maxCharacters,
        ], required: ["language"]),
        annotations: readOnly)

    // MARK: Beyond the chat store

    private static let copyNote = """
        Read live from the database, through WhatsApp's write-ahead log; the answer says \
        which database and when.
        """

    static let calls = Tool(
        name: callsName,
        title: "List calls",
        description: """
            Lists voice and video calls from WhatsApp's call history, newest first by \
            default: when, how long, incoming or outgoing, missed or not, video or voice, \
            the group if it was a group call, and the participants' addresses, clipped to \
            \(Configuration.participantsWidth) characters in each row.

            \(paging("calls", Configuration.limitRange, Configuration.defaultLimit)) \
            from_date and to_date narrow by date.

            The outcome is reported as the number WhatsApp stored. Which number means \
            answered, declined or failed has not been established, and is not guessed. \
            \(copyNote)
            """,
        inputSchema: object(properties: [
            "from_date": fromDate,
            "to_date": toDate,
            "order": orderProperty,
            "limit": limit("calls", range: Configuration.limitRange, default: Configuration.defaultLimit),
            "offset": offset,
        ]),
        annotations: readOnly)

    static let locationSharing = Tool(
        name: locationSharingName,
        title: "List live-location sharing",
        description: """
            Lists live-location sharing as one list: first the sessions you started (chat, \
            when, when they end), newest first, then who they were shared with, latest \
            expiry first.

            \(paging("rows", Configuration.limitRange, Configuration.defaultLimit))

            Coordinates are not included — they sit in a binary field this server does not \
            decode. A location sent as an ordinary message is in chat_get and media_list, \
            with its coordinates. \(copyNote)
            """,
        inputSchema: object(properties: [
            "limit": limit("rows", range: Configuration.limitRange, default: Configuration.defaultLimit),
            "offset": offset,
        ]),
        annotations: readOnly)

    static let labels = Tool(
        name: labelsName,
        title: "List labels",
        description: """
            Lists WhatsApp Business labels in WhatsApp's own order, with their id, name, \
            colour id and how many chats or contacts carry each. With 'label_id', lists \
            what carries that label instead, newest first.

            \(paging("rows", Configuration.limitRange, Configuration.defaultLimit))

            Labels exist only on accounts that use them; an empty list is normal. \
            \(copyNote)
            """,
        inputSchema: object(properties: [
            "label_id": identifier(
                "Optional label id from this tool's own list. Omit to list the labels.",
                range: Configuration.labelIdentifierRange),
            "limit": limit("rows", range: Configuration.limitRange, default: Configuration.defaultLimit),
            "offset": offset,
        ]),
        annotations: readOnly)

    static let addressBook = Tool(
        name: addressBookName,
        title: "Search WhatsApp's address book",
        description: """
            Looks up people in WhatsApp's own copy of your address book, by name: full, \
            given and last name, business name, phone number, LID, WhatsApp id, username \
            and 'about' text. Matching ignores case and accents.

            \(paging("entries", Configuration.limitRange, Configuration.defaultLimit))

            This is WhatsApp's own table, which can disagree with any other address book. \
            \(copyNote)
            """,
        inputSchema: object(properties: [
            "name": string("Optional text to match against names and the phone number."),
            "limit": limit("entries", range: Configuration.limitRange, default: Configuration.defaultLimit),
            "offset": offset,
        ]),
        annotations: readOnly)

    static let lidLookup = Tool(
        name: lidLookupName,
        title: "Look up a LID or phone number",
        description: """
            Given a …@lid address or a phone number, returns every pairing and name WhatsApp \
            recorded for it in its LID and extended-chat databases, each labelled with the \
            table it came from, table by table.

            \(paging("records", Configuration.limitRange, Configuration.defaultLimit))

            No result means WhatsApp stored no pairing for that value on this Mac, not that \
            none exists. Coverage of these tables has not been measured. \(copyNote)
            """,
        inputSchema: object(
            properties: [
                "value": string("A LID (with or without @lid) or a phone number (digits)."),
                "limit": limit("records", range: Configuration.limitRange, default: Configuration.defaultLimit),
                "offset": offset,
            ], required: ["value"]),
        annotations: readOnly)

    static let channels = Tool(
        name: channelsName,
        title: "List channels",
        description: """
            Lists WhatsApp channels this Mac knows about, by name: address, name, and who \
            added it. Matching on the name ignores case and accents.

            \(paging("channels", Configuration.limitRange, Configuration.defaultLimit)) \
            \(copyNote)
            """,
        inputSchema: object(properties: [
            "name": string("Optional text to match against the channel name."),
            "limit": limit("channels", range: Configuration.limitRange, default: Configuration.defaultLimit),
            "offset": offset,
        ]),
        annotations: readOnly)

    // MARK: Raw database access

    private static let databaseProperty: Value = .object([
        "type": .string("string"),
        "enum": .array(AllowedDatabase.allCases.map { .string($0.rawValue) }),
        "description": .string(
            "Which of WhatsApp's databases to read. A fixed list: the container also holds "
                + "encryption keys that no tool here opens."),
    ])

    private static let snapshotHelp = """
        Reads the database live, through WhatsApp's write-ahead log, so the newest rows \
        are included; the answer says when it was read. Only the tables the database \
        itself declares can be read — not SQLite's internal ones, such as raw pages.
        """

    static let dbTables = Tool(
        name: dbTablesName,
        title: "List database tables",
        description: """
            Lists the tables and views in one of WhatsApp's local databases (chat store, \
            contacts, call history, labels, locations, stickers, status, channels and the \
            rest), by name. Names only, no rows.

            \(paging("tables", Configuration.tableLimitRange, Configuration.defaultTableLimit))

            Use it to see what exists before db_schema and db_query. \(snapshotHelp)
            """,
        inputSchema: object(
            properties: [
                "db": databaseProperty,
                "limit": limit(
                    "tables", range: Configuration.tableLimitRange,
                    default: Configuration.defaultTableLimit),
                "offset": offset,
            ], required: ["db"]),
        annotations: readOnly)

    static let dbSchema = Tool(
        name: dbSchemaName,
        title: "Read database schema",
        description: """
            Returns the CREATE statements of one database, tables first, then views, then \
            indexes, or those of one table. Structure only, no rows. Each statement is \
            whole; none is cut.

            \(paging("statements", Configuration.schemaLimitRange, Configuration.defaultSchemaLimit)) \
            'table' narrows to one table and its indexes.

            The schema is WhatsApp's own and undocumented, so read it rather than assuming \
            a column name. \(snapshotHelp)
            """,
        inputSchema: object(
            properties: [
                "db": databaseProperty,
                "table": string("Optional table or view name from db_tables. Omit for everything."),
                "limit": limit(
                    "statements", range: Configuration.schemaLimitRange,
                    default: Configuration.defaultSchemaLimit),
                "offset": offset,
            ], required: ["db"]),
        annotations: readOnly)

    static let dbQuery = Tool(
        name: dbQueryName,
        title: "Query a database",
        description: """
            Runs one SELECT (or WITH … SELECT) statement against one of WhatsApp's \
            databases and returns its rows, in the statement's own order, as tab-separated \
            text, with a blob shown as its size and every value clipped to at most \
            \(Configuration.cellWidth) characters, fewer when a statement names many columns. \
            Anything else is refused: a second \
            statement, ATTACH, PRAGMA, and any statement that would change data. A \
            long-running statement is stopped.

            \(Configuration.defaultQueryLimit) rows by default, fewer when they are wide. When \
            more exist, the first lines of the result say so and give the offset of the next \
            page: pass limit (up to \(Configuration.queryLimitRange.upperBound)) and offset for \
            the rest, with an ORDER BY so pages do not overlap. Read a clipped value with \
            substr().

            This is the escape hatch for what the dedicated tools do not cover. Prefer \
            chats_list, chat_get and media_list for ordinary reading, and call db_schema \
            first — column names are WhatsApp's and change between versions. \(snapshotHelp)
            """,
        inputSchema: object(
            properties: [
                "db": databaseProperty,
                "sql": string("A single SELECT or WITH … SELECT statement."),
                "limit": limit(
                    "rows", range: Configuration.queryLimitRange,
                    default: Configuration.defaultQueryLimit),
                "offset": offset,
            ], required: ["db", "sql"]),
        annotations: readOnly)

}
