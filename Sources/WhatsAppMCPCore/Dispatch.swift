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
    private let explorer: (any DatabaseExplorer)?
    private let reader: (any DomainReader)?
    private let mediaFiles: MediaFiles?
    private let calendar: Calendar
    private let format: Format

    public init(
        store: any WhatsAppStore, explorer: (any DatabaseExplorer)? = nil,
        reader: (any DomainReader)? = nil, mediaFiles: MediaFiles? = nil,
        calendar: Calendar = .current
    ) {
        self.store = store
        self.explorer = explorer
        self.reader = reader
        self.mediaFiles = mediaFiles
        self.calendar = calendar
        self.format = Format(calendar: calendar)
    }

    public func handle(_ parameters: CallTool.Parameters) async -> CallTool.Result {
        do {
            return .init(content: try await contents(parameters), isError: false)
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

    /// Every tool answers with text except `media_view`, which also returns images.
    private func contents(_ parameters: CallTool.Parameters) async throws -> [Tool.Content] {
        if parameters.name == ToolCatalog.mediaViewName {
            let availability = store.availability()
            guard availability.isUsable else { throw ToolError.storeUnavailable(availability) }
            return try await mediaView(Arguments(parameters.arguments, calendar: calendar))
        }
        return [.text(text: try await run(parameters), annotations: nil, _meta: nil)]
    }

    private func run(_ parameters: CallTool.Parameters) async throws -> String {
        let arguments = Arguments(parameters.arguments, calendar: calendar)

        // Answered before the availability check: "why can nothing be read" is exactly the
        // question asked when the database is missing or the wrong shape.
        if parameters.name == ToolCatalog.statusName {
            return format.status(
                store.databaseInfo(), availability: store.availability(),
                binaryPath: Self.binaryPath, snapshots: explorer?.existingSnapshots() ?? [])
        }

        // Before the chat-store check on purpose: db_* is how a broken chat store gets
        // diagnosed, and it reads other databases that may be perfectly fine.
        switch parameters.name {
        case ToolCatalog.dbTablesName, ToolCatalog.dbSchemaName, ToolCatalog.dbQueryName:
            return try databaseTool(parameters.name, arguments)
        case ToolCatalog.callsName, ToolCatalog.locationSharingName, ToolCatalog.labelsName,
            ToolCatalog.addressBookName, ToolCatalog.lidLookupName, ToolCatalog.channelsName:
            return try domainTool(parameters.name, arguments)
        default:
            break
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

        case ToolCatalog.mediaGetName:
            return try await mediaGet(arguments)

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

    // MARK: Attachment files

    /// The message, its attachment, and the file's resolved URL when it is on this Mac.
    private func attachment(_ arguments: Arguments) async throws -> (
        message: Message, attachment: Attachment, url: URL?
    ) {
        let id = try arguments.requiredInt("message_id")
        guard let message = try await store.message(id: id) else {
            throw ToolError.messageNotFound(id: id)
        }
        guard case .attachment(let attachment) = message.body else {
            throw ToolError.noAttachment(id: id)
        }
        guard let stored = attachment.localPath else { return (message, attachment, nil) }
        guard let mediaFiles else {
            throw ToolError.mediaProblem("Attachment files are not configured in this server.")
        }
        guard let url = mediaFiles.contained(stored) else {
            // Gone between the store's check and this one: absent, not escaping.
            guard FileManager.default.fileExists(atPath: stored) else {
                return (message, attachment, nil)
            }
            throw ToolError.mediaProblem(
                "The stored path for message \(id) is not inside WhatsApp's Message folder, "
                    + "so no tool here will open it.")
        }
        return (message, attachment, url)
    }

    private func mediaGet(_ arguments: Arguments) async throws -> String {
        let (message, attachment, url) = try await attachment(arguments)
        guard let url else { return format.mediaMissing(message, attachment: attachment) }
        do {
            return format.mediaFacts(
                message, attachment: attachment, url: url, facts: try MediaFiles.facts(of: url))
        } catch {
            throw ToolError.mediaProblem("The file could not be read: \(error.localizedDescription)")
        }
    }

    private func mediaView(_ arguments: Arguments) async throws -> [Tool.Content] {
        let (message, attachment, url) = try await attachment(arguments)
        func text(_ value: String) -> Tool.Content { .text(text: value, annotations: nil, _meta: nil) }
        guard let url else { return [text(format.mediaMissing(message, attachment: attachment))] }

        let heading = format.mediaHeading(message, attachment: attachment)
        do {
            switch attachment.kind {
            case .photo, .sticker, .gif:
                let jpeg = try MediaFiles.jpegData(of: url)
                return [
                    .image(data: jpeg.base64EncodedString(), mimeType: "image/jpeg", annotations: nil, _meta: nil),
                    text(heading),
                ]

            case .video:
                let count = try arguments.int("frames", default: 4, in: 1...8)
                let (frames, seconds) = try await MediaFiles.keyFrames(of: url, count: count)
                var content: [Tool.Content] = frames.map {
                    .image(data: $0.base64EncodedString(), mimeType: "image/jpeg", annotations: nil, _meta: nil)
                }
                content.append(
                    text(
                        heading + "\n\(frames.count) frames, evenly spaced over \(Int(seconds.rounded())) s. "
                            + "For what is said, use audio_transcribe with this message id."))
                return content

            case .document:
                let mime = MediaFiles.mimeType(of: url)
                if mime == "application/pdf" {
                    return [text(heading + "\n\n" + format.documentText(try MediaFiles.pdfText(of: url), pdf: true))]
                }
                if mime.hasPrefix("text/") {
                    return [text(heading + "\n\n" + format.documentText(try MediaFiles.plainText(of: url), pdf: false))]
                }
                return [
                    text(
                        heading + "\n\nNo viewer for \(mime): this server reads images, PDFs, text "
                            + "and video frames. media_get gives the path and hash.")
                ]

            case .voiceNote, .audioFile:
                return [text(heading + "\n\nAudio is not played here. Use audio_transcribe with this message id.")]
            }
        } catch let failure as MediaFiles.ViewError {
            switch failure {
            case .unreadable(let detail):
                throw ToolError.mediaProblem("This attachment could not be opened: \(detail).")
            case .tooManyPixels(let pixels, let limit):
                throw ToolError.mediaProblem(
                    "This image is \(pixels) pixels, over the \(limit)-pixel limit for viewing.")
            case .tooLarge(let size, let limit):
                throw ToolError.mediaProblem(
                    "This file is \(size) bytes, over the \(limit)-byte limit for viewing.")
            case .locked:
                throw ToolError.mediaProblem("This PDF is password-protected; its text cannot be read.")
            }
        }
    }

    private func domainTool(_ name: String, _ arguments: Arguments) throws -> String {
        guard let reader else { throw ToolError.explorerUnavailable }
        let limit = try arguments.int(
            "limit", default: Configuration.pageSize, in: Configuration.pageSizeRange)
        do {
            switch name {
            case ToolCatalog.callsName:
                var query = CallQuery()
                query.after = try arguments.optionalDate("after")
                query.before = try arguments.optionalDate("before")
                if let after = query.after, let before = query.before, before < after {
                    throw ToolError.rangeInverted
                }
                query.newestFirst = try arguments.newestFirst()
                query.limit = limit
                query.offset = try arguments.int("offset", default: 0, in: Configuration.offsetRange)
                let (calls, snapshot) = try reader.calls(matching: query)
                return format.calls(calls, snapshot: snapshot)

            case ToolCatalog.locationSharingName:
                let (sharing, snapshot) = try reader.locationSharing(limit: limit)
                return format.locationSharing(sharing, snapshot: snapshot)

            case ToolCatalog.labelsName:
                if let id = try arguments.optionalInt("label_id") {
                    let (label, entities, snapshot) = try reader.labeledEntities(
                        labelID: id, limit: limit)
                    guard let label else {
                        throw ToolError.badArgument(
                            name: "label_id", reason: "no label has id \(id); call labels_list without it")
                    }
                    return format.labeledEntities(entities, label: label, snapshot: snapshot)
                }
                let (labels, snapshot) = try reader.labels()
                return format.labels(labels, snapshot: snapshot)

            case ToolCatalog.addressBookName:
                var query = AddressBookQuery()
                query.name = arguments.optionalString("name")
                query.limit = limit
                query.offset = try arguments.int("offset", default: 0, in: Configuration.offsetRange)
                let (entries, snapshot) = try reader.addressBook(matching: query)
                return format.addressBook(entries, snapshot: snapshot)

            case ToolCatalog.lidLookupName:
                let value = try arguments.requiredString("value")
                let (matches, snapshots, notes) = try reader.lidLookup(value)
                return format.lidMatches(matches, value: value, snapshots: snapshots, notes: notes)

            default:
                let (channels, snapshot) = try reader.channels(
                    name: arguments.optionalString("name"), limit: limit)
                return format.channels(channels, snapshot: snapshot)
            }
        } catch let failure as SnapshotError {
            throw ToolError.storeFailure(failure.message)
        } catch let failure as ReadOnlyDatabase.QueryFailure {
            throw ToolError.storeFailure(failure.detail)
        }
    }

    private func databaseTool(_ name: String, _ arguments: Arguments) throws -> String {
        guard let explorer else { throw ToolError.explorerUnavailable }
        let requested = try arguments.requiredString("db")
        guard let database = AllowedDatabase(rawValue: requested) else {
            throw ToolError.databaseNotAllowed(requested)
        }
        do {
            switch name {
            case ToolCatalog.dbTablesName:
                let (entries, snapshot) = try explorer.tables(in: database)
                return format.databaseTables(entries, snapshot: snapshot)

            case ToolCatalog.dbSchemaName:
                let (statements, snapshot) = try explorer.schema(
                    of: database, table: arguments.optionalString("table"))
                return format.databaseSchema(statements, snapshot: snapshot)

            default:
                let limit = try arguments.int(
                    "limit", default: SnapshotDatabaseExplorer.defaultRowLimit,
                    in: SnapshotDatabaseExplorer.rowLimitRange)
                let result = try explorer.select(
                    try arguments.requiredString("sql"), in: database, limit: limit)
                return format.queryResult(result, limit: limit)
            }
        } catch let refusal as ReadOnlyDatabase.SelectRefusal {
            throw ToolError.queryRefused(refusal.detail)
        } catch let failure as SnapshotError {
            throw ToolError.storeFailure(failure.message)
        } catch let failure as ReadOnlyDatabase.QueryFailure {
            throw ToolError.storeFailure(failure.detail)
        }
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
