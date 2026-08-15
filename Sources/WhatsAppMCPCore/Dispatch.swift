import Foundation
import MCP

/// Routes a `tools/call` to the store and renders the answer.
///
/// Never opens the chat database itself — every read goes through `WhatsAppStore`, which
/// is what lets the tests drive every branch below with no database on disk.
///
/// This server reads and nothing else. There is no sender, no shortcut and no Apple
/// event anywhere beneath this type, so no tool routed here can reach outside this Mac.
public struct WhatsAppTools: Sendable {
    private let store: any WhatsAppStore
    private let calendar: Calendar
    private let format: Format

    public init(store: any WhatsAppStore, calendar: Calendar = .current) {
        self.store = store
        self.calendar = calendar
        self.format = Format(calendar: calendar)
    }

    public func handle(_ parameters: CallTool.Parameters) async -> CallTool.Result {
        do {
            let text = try await run(parameters)
            return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
        } catch let error as ToolError {
            return .init(
                content: [.text(text: error.message, annotations: nil, _meta: nil)], isError: true)
        } catch {
            return .init(
                content: [
                    .text(
                        text: ToolError.storeFailure(error.localizedDescription).message,
                        annotations: nil, _meta: nil)
                ], isError: true)
        }
    }

    private func run(_ parameters: CallTool.Parameters) async throws -> String {
        let arguments = Arguments(parameters.arguments, calendar: calendar)

        // Answered before the availability check: "why can nothing be read" is exactly the
        // question asked when the database is missing or the wrong shape.
        if parameters.name == ToolCatalog.statusName {
            return format.status(
                store.databaseInfo(), availability: store.availability(),
                binaryPath: Self.binaryPath)
        }

        let availability = store.availability()
        guard availability.isUsable else { throw ToolError.storeUnavailable(availability) }

        switch parameters.name {
        case ToolCatalog.chatsName:
            return try await chats(arguments)

        case ToolCatalog.chatGetName:
            return try await chat(arguments)

        case ToolCatalog.searchName:
            return try await search(arguments)

        case ToolCatalog.messageGetName:
            return try await message(arguments)

        case ToolCatalog.mediaName:
            return try await media(arguments)

        case ToolCatalog.groupGetName:
            return try await group(arguments)

        default:
            throw ToolError.badArgument(
                name: "name", reason: "'\(parameters.name)' is not a tool of this server")
        }
    }

    // MARK: Reads

    private func chats(_ arguments: Arguments) async throws -> String {
        var query = ChatQuery()
        query.name = arguments.optionalString("name")
        query.kinds = try arguments.chatKinds("kinds")
        query.includeArchived = arguments.bool("include_archived")
        query.includeHidden = arguments.bool("include_hidden")
        query.limit = try arguments.int(
            "limit", default: Configuration.pageSize, in: Configuration.pageSizeRange)
        query.offset = try arguments.int("offset", default: 0, in: Configuration.offsetRange)

        return format.chats(try await store.chats(matching: query), query: query)
    }

    private func chat(_ arguments: Arguments) async throws -> String {
        let id = try arguments.requiredInt("chat_id")
        guard let summary = try await store.chat(id: id) else {
            throw ToolError.chatNotFound(id: id)
        }

        var query = try messageQuery(arguments)
        query.chatID = id

        return format.chatPage(try await store.messages(matching: query), chat: summary, query: query)
    }

    private func search(_ arguments: Arguments) async throws -> String {
        var query = try messageQuery(arguments)
        query.chatID = try arguments.optionalInt("chat_id")
        query.text = arguments.optionalString("query")

        return format.searchResults(try await store.messages(matching: query), query: query)
    }

    private func message(_ arguments: Arguments) async throws -> String {
        let id = try arguments.requiredInt("message_id")
        guard let message = try await store.message(id: id) else {
            throw ToolError.messageNotFound(id: id)
        }
        return format.messageDetail(message)
    }

    private func media(_ arguments: Arguments) async throws -> String {
        var query = try messageQuery(arguments)
        query.chatID = try arguments.optionalInt("chat_id")
        // The catalogue calls this property "kinds". Reading a name the schema does not
        // declare cannot fail loudly — it just returns nothing, and the filter quietly
        // never applies.
        let requestedKinds = try arguments.mediaKinds("kinds")
        // WhatsApp attaches a ZWAMEDIAITEM row to an ordinary text message for a link
        // preview's thumbnail, so "has a media row" is not the same question as "is an
        // attachment". An empty "kinds" argument therefore means every kind this tool
        // covers, never "no filter" — the empty-means-everything convention chat_get uses
        // would let those text messages through dressed as attachments.
        query.kinds = requestedKinds.isEmpty ? MediaKind.allCases : requestedKinds

        return format.media(try await store.media(matching: query), query: query)
    }

    private func group(_ arguments: Arguments) async throws -> String {
        let id = try arguments.requiredInt("chat_id")
        guard let summary = try await store.chat(id: id) else {
            throw ToolError.chatNotFound(id: id)
        }
        guard summary.kind == .group else {
            throw ToolError.notAGroup(id: id, kind: summary.kind)
        }
        guard let group = try await store.group(chatID: id) else {
            throw ToolError.storeFailure(
                "chat \(id) is a group but has no ZWAGROUPINFO row — the database may be "
                    + "mid-sync; try again after opening WhatsApp")
        }
        return format.group(group, chat: summary)
    }

    /// The filters `chat_get`, `whatsapp_search` and `media_list` share.
    ///
    /// Each mirrors a column the store already holds. Nothing here is derived, ranked or
    /// scored: the rows go up as they are and the reading of them happens above.
    private func messageQuery(_ arguments: Arguments) throws -> MessageQuery {
        var query = MessageQuery()
        query.after = try arguments.optionalDate("after")
        query.before = try arguments.optionalDate("before")
        query.fromMe = arguments.optionalBool("from_me")
        query.starredOnly = arguments.bool("starred_only")
        query.newestFirst = try arguments.newestFirst()
        query.limit = try arguments.int(
            "limit", default: Configuration.pageSize, in: Configuration.pageSizeRange)
        query.offset = try arguments.int("offset", default: 0, in: Configuration.offsetRange)

        if let after = query.after, let before = query.before, before < after {
            throw ToolError.rangeInverted
        }
        return query
    }

    static var binaryPath: String {
        CommandLine.arguments.first.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? "(unknown)"
    }
}
