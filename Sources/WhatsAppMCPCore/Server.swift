import Foundation
import MCP

public enum WhatsAppMCPServer {

    public static let name = "whatsapp-mcp"
    public static let version = "1.0.0"

    /// Returned from `initialize`. It carries what per-tool descriptions cannot state
    /// once: that this server only reads, that the schema is undocumented, and what
    /// WhatsApp simply does not keep on this Mac.
    public static let instructions = """
        Read-only access to WhatsApp on this Mac.

        Everything comes from WhatsApp's own local database, opened read-only and \
        immutable: this server cannot write to it, cannot lock it, and cannot disturb \
        WhatsApp's own writes. There is no tool here that sends, edits or deletes \
        anything, and no route to WhatsApp's network at all. Unusually, no macOS \
        permission is involved either — WhatsApp's container is not protected the way \
        Apple's own stores are. whatsapp_status says whether the file is present and the \
        shape the queries expect.

        THAT SHAPE IS NOT A CONTRACT. The database is WhatsApp's private storage, \
        undocumented and free to change in any update. If whatsapp_status reports an \
        unexpected shape, the reads are wrong and not merely empty — say so rather than \
        reporting that someone has no messages.

        The newest messages can be missing briefly: WhatsApp buffers writes, and \
        whatsapp_status reports when there are unwritten changes pending.

        Workflow: chats_list to see what exists, chat_get for one conversation, \
        whatsapp_search across all of them, message_get to open one message up, \
        media_list for what was shared rather than said, group_get for a group's roster \
        and details. Ids are row ids in the local database — they are not WhatsApp \
        identifiers and do not survive a reinstall, so look them up again rather than \
        reusing one from earlier in the conversation.

        FOUR THINGS ARE NOT IN THIS DATABASE, and are absent from WhatsApp's own storage \
        rather than missed by these tools: any mapping from a …@lid address to a phone \
        number; any disappearing-message setting or TTL; the text of a message deleted for \
        everyone, which WhatsApp clears in place with no second copy and no link to what \
        it replaced; and any meaning for a delivery code, which is stored as a number \
        nobody has matched to sent, delivered or read. Say so plainly rather than implying \
        the data might be found another way.
        """

    /// The store is a parameter so the whole server can be driven by a double. Nothing in
    /// this function opens a database by itself.
    public static func run(
        store: (any WhatsAppStore)? = nil,
        configuration: Configuration = Configuration()
    ) async throws {
        let tools = WhatsAppTools(
            store: store ?? SystemWhatsAppStore(path: configuration.databasePath))
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
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }
}
