import Foundation
import MCP

public enum WhatsAppMCPServer {

    public static let name = "whatsapp-mcp"
    public static let version = "1.5.0"

    /// Returned from `initialize`. It carries what per-tool descriptions cannot state
    /// once: that this server never changes WhatsApp and keeps nothing, that
    /// the schema is undocumented, and what WhatsApp simply does not keep on this Mac.
    public static let instructions = """
        Read access to WhatsApp on this Mac. This server never changes WhatsApp's data: it \
        cannot write, delete or send a message, and has no route to WhatsApp's network or to \
        any other network. Reading a database in WAL mode does update that database's \
        -shm index file, which SQLite uses to coordinate readers with the writer; it holds \
        no messages. On recent macOS, reading \
        WhatsApp's container needs Full Disk Access for this server's program, and every \
        rebuilt or updated copy needs it again. whatsapp_status says whether macOS allowed \
        the read (and, if it refused, the exact steps), whether the chat database is \
        present, and the shape the queries expect. If a tool says macOS refused access to \
        WhatsApp's data folder (ACCESS DENIED in whatsapp_status), give the person those \
        steps; it is not a missing file.

        It keeps nothing. The only file it makes is a scratch directory for converting \
        audio, in ~/Library/Caches/whatsapp-mcp, deleted when the call ends; transcripts \
        and database content are never stored — every database is read live, and a \
        transcript exists only in the answer. db_query can read only the tables a \
        database itself declares, and never key material.

        THE SHAPE OF WHATSAPP'S DATA IS NOT A CONTRACT. The databases are WhatsApp's private \
        storage, undocumented and free to change in any update. If a tool reports a missing \
        table or column, the reads are wrong and not merely empty — say so rather than \
        reporting that someone has no messages, calls or contacts.

        The newest messages are included: the databases are read through WhatsApp's \
        write-ahead log. A message WhatsApp has not committed yet is not visible, and \
        every answer from a database other than the chat store says when it was read.

        Workflow: chats_list to see what exists, chat_get for one conversation, \
        whatsapp_search across all of them (with starred_only=true and no phrase it lists \
        every starred message), message_get to open one message up — it shows the message \
        a reply quotes and who reacted with which emoji — media_list for what was shared \
        rather than said, group_get for a group's roster. To open an \
        attachment: media_get for the file's facts, media_view to see a photo, read a PDF or \
        see a video's frames, audio_transcribe for sound. Beyond messages: calls_list, \
        location_sharing_list, labels_list, address_book_list, channels_list and \
        lid_lookup. db_tables, db_schema and db_query read any other WhatsApp database \
        directly — one SELECT, rows capped, call db_schema first because column names are \
        WhatsApp's. Key material and raw protocol queues are refused. Ids are row ids in \
        the local database — they are not WhatsApp identifiers and do not survive a \
        reinstall, so look them up again rather than reusing one from earlier.

        TRANSCRIPTS ARE AUTOMATIC. audio_transcribe uses the speech recognition built into \
        macOS, on this Mac, and can be wrong. It needs the language spoken, as a full tag \
        (es-ES, en-US; a bare language only when it has a single model): macOS cannot detect it, and Basque (eu) and Catalan (ca) were not in its list when \
        this was written — the tool says what the engine offers rather than guessing in \
        another language. macOS 27 opens \
        WhatsApp's Ogg Opus voice notes, MP3 and M4A itself; a video's sound track, containers \
        it cannot open (Matroska, for one) and, on older macOS, possibly voice notes need \
        ffmpeg installed.

        WHAT IS NOT IN THE CHAT DATABASE, and is absent from WhatsApp's own storage rather \
        than missed by these tools: a mapping from a …@lid address to a phone number there \
        (other databases have pairing tables, which lid_lookup reads, and whose coverage is \
        not measured); any disappearing-message setting or TTL; the text of a message \
        deleted for everyone, which WhatsApp clears in place with no second copy and no link \
        to what it replaced; and any meaning for a delivery code, which is stored as a \
        number nobody has matched to sent, delivered or read; and who starred a message or \
        when, since a star is only a yes/no flag. Say so plainly rather than \
        implying the data might be found another way.

        WhatsApp status updates are not covered: the structure of that database could not \
        be verified, so there is no tool for them. db_query can reach it.
        """

    /// The store is a parameter so the whole server can be driven by a double. Nothing in
    /// this function opens a database by itself.
    public static func run(
        store: (any WhatsAppStore)? = nil,
        explorer: (any DatabaseExplorer)? = nil,
        reader: (any DomainReader)? = nil,
        transcription: TranscriptionService? = nil,
        configuration: Configuration = Configuration()
    ) async throws {
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
        let server = Server(
            name: name,
            version: version,
            instructions: instructions,
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: ToolCatalog.all())
        }
        await server.withMethodHandler(CallTool.self) { await tools.handle($0) }

        // The default StdioTransport logger is a no-op handler. Leave it that way: a
        // logger writing to stdout would interleave with the JSON-RPC stream and break
        // every response after the first log line.
        ProcessCleanup.shared.installSignalHandlers()
        Diagnostics.started(version: version)
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
        // The client closed stdin. Work still in flight dies with the process, and its
        // temporary files and ffmpeg would outlive it.
        ProcessCleanup.shared.run()
    }
}
