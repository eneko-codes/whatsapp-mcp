import Foundation

public enum WhatsAppMCPServer {

    public static let name = "whatsapp-mcp"
    public static let version = "2.0.0"

    /// Returned from `initialize`. It carries what per-tool descriptions cannot state
    /// once: that this server never changes WhatsApp and keeps nothing, that
    /// the schema is undocumented, and what WhatsApp simply does not keep on this Mac.
    public static let instructions = """
        Read access to WhatsApp on this Mac. This server never changes WhatsApp's data: it \
        cannot write, delete or send a message, and has no route to any network. Ids are \
        row ids in the local database, not WhatsApp identifiers: look them up again rather \
        than reusing one from an earlier conversation.

        Workflow: chats_list to see what exists, chat_get for one conversation, \
        whatsapp_search across all of them (starred_only=true with no phrase lists every \
        starred message), message_get to open one message whole — the message a reply \
        quotes and who reacted with which emoji — media_list for what was shared rather \
        than said, group_get for a group's members. To open an attachment: media_get for \
        the file's facts, media_view to see a photo, read a PDF or see a video's frames, \
        audio_transcribe for sound. Beyond messages: calls_list, location_sharing_list, \
        labels_list, address_book_list, channels_list and lid_lookup. db_tables, db_schema \
        and db_query read any other WhatsApp database: one SELECT, and call db_schema first \
        because column names are WhatsApp's. Key material is refused.

        EVERY ANSWER IS BOUNDED, and its first lines say what it left out and the exact \
        arguments that return the rest. Listings come \(Configuration.defaultLimit) rows to \
        a page (messages \(Configuration.defaultMessageLimit)): pass limit and offset. A \
        row clips a message's text to \(Configuration.textWidth) characters; message_get \
        has it whole. A long text (one message, a document, a transcript) comes \
        \(Configuration.defaultMaxCharacters) characters at a time: pass character_offset \
        and max_characters. Dates: from_date and to_date, both inclusive.

        If a tool says macOS refused access to WhatsApp's data folder (ACCESS DENIED in \
        whatsapp_status), it is not a missing file: this server's program needs Full Disk \
        Access, and a copy signed ad hoc needs it again after every rebuild or update. \
        whatsapp_status gives the steps; pass them on.

        THE SHAPE OF WHATSAPP'S DATA IS NOT A CONTRACT. The databases are WhatsApp's \
        private, undocumented storage. If a tool reports a missing table or column, the \
        reads are wrong, not empty — say so rather than reporting that someone has no \
        messages, calls or contacts. The newest messages are included, through the \
        write-ahead log; reading updates only SQLite's -shm index file, which holds no \
        messages.

        It keeps nothing: the only file it makes is a scratch folder for converting audio, \
        in ~/Library/Caches/whatsapp-mcp, deleted when the call ends.

        TRANSCRIPTS ARE AUTOMATIC and can be wrong. audio_transcribe needs the language \
        spoken as a full tag (es-ES, en-US): macOS cannot detect it, and Basque (eu) and \
        Catalan (ca) were not in its list when this was written. A video's sound track and \
        containers macOS cannot open need ffmpeg installed.

        NOT IN WHATSAPP'S STORAGE at all, rather than missed by these tools: a phone number \
        for a …@lid address in the chat database (lid_lookup reads other pairing tables, of \
        unmeasured coverage); any disappearing-message setting; the text of a message \
        deleted for everyone; any meaning for a delivery code, stored as a bare number; and \
        who starred a message or when. Say so plainly. Status updates have no tool: their \
        database could not be verified; db_query can reach it.
        """

    /// The store is a parameter so the whole server can be driven by a double. Nothing in
    /// this function opens a database by itself.
    public static func run(
        store: (any WhatsAppStore)? = nil,
        explorer: (any DatabaseExplorer)? = nil,
        reader: (any DomainReader)? = nil,
        transcription: TranscriptionService? = nil,
        configuration: Configuration = Configuration()
    ) async {
        let databases = ContainerDatabases(containerDirectory: configuration.containerDirectory)
        let mediaFiles = MediaFiles(containerDirectory: configuration.containerDirectory)
        let tools = WhatsAppTools(
            store: store ?? SystemWhatsAppStore(path: configuration.databasePath),
            explorer: explorer ?? LiveDatabaseExplorer(databases: databases),
            reader: reader ?? LiveDomainReader(databases: databases),
            mediaFiles: mediaFiles,
            transcription: transcription
                ?? TranscriptionService(
                    mediaFiles: mediaFiles,
                    scratchDirectory: URL(fileURLWithPath: configuration.scratchDirectory),
                    converter: (configuration.ffmpegPath.map { URL(fileURLWithPath: $0) }
                        ?? FFmpegConverter.locate()).map { FFmpegConverter(executable: $0) },
                    engine: NativeSpeechTranscriber()))
        ProcessCleanup.shared.installSignalHandlers()
        Diagnostics.started(version: version)
        await serveStandardStreams(handler: handler(tools: tools))
        // The client closed stdin. Work still in flight dies with the process, and its
        // temporary files and ffmpeg would outlive it.
        ProcessCleanup.shared.run()
    }

    public static func handler(tools: WhatsAppTools) -> MCPHandler {
        MCPHandler(
            name: name, version: version, instructions: instructions,
            catalog: ToolCatalog.all(), tools: tools)
    }
}
