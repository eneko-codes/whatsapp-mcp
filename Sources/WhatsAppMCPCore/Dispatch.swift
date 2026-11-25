import Foundation

/// Routes a `tools/call` to the store and renders the answer.
///
/// Never opens the chat database itself — every read goes through `WhatsAppStore`, which
/// is what lets the tests drive every branch below with no database on disk.
///
/// This server never changes WhatsApp. There is no sender, no shortcut and no Apple
/// event anywhere beneath this type, so no tool routed here can reach outside this Mac;
/// the only file a tool makes is a scratch directory, deleted when the call ends.
public struct WhatsAppTools: ToolHandler {
    private let store: any WhatsAppStore
    private let explorer: (any DatabaseExplorer)?
    private let reader: (any DomainReader)?
    private let mediaFiles: MediaFiles?
    private let transcription: TranscriptionService?
    private let calendar: Calendar
    private let format: Format
    private let timeout: Duration

    public init(
        store: any WhatsAppStore, explorer: (any DatabaseExplorer)? = nil,
        reader: (any DomainReader)? = nil, mediaFiles: MediaFiles? = nil,
        transcription: TranscriptionService? = nil, calendar: Calendar = .current,
        timeout: Duration = Configuration.callTimeout
    ) {
        self.store = store
        self.explorer = explorer
        self.reader = reader
        self.mediaFiles = mediaFiles
        self.transcription = transcription
        self.calendar = calendar
        self.format = Format(calendar: calendar)
        self.timeout = timeout
    }

    public func handle(_ parameters: ToolCall) async -> ToolOutput {
        let started = ContinuousClock.now
        let outcome = await Deadline.run(within: timeout) {
            do {
                return Result<[ToolOutput.Block], any Error>.success(try await contents(parameters))
            } catch {
                return .failure(error)
            }
        }
        switch outcome {
        case .success(let blocks)?:
            return ToolOutput(content: blocks, isError: false)
        case .failure(let error)?:
            Diagnostics.toolFailed(parameters.name, error: error, since: started)
            let message =
                (error as? ToolError)?.message
                ?? ToolError.storeFailure(error.localizedDescription).message
            return ToolOutput(text: message, isError: true)
        case nil:
            let error = ToolError.timedOut(seconds: Int(timeout.components.seconds))
            Diagnostics.toolFailed(parameters.name, error: error, since: started)
            return ToolOutput(text: error.message, isError: true)
        }
    }

    /// Every tool answers with text except `media_view`, which also returns images.
    private func contents(_ parameters: ToolCall) async throws -> [ToolOutput.Block] {
        guard let tool = ToolCatalog.all().first(where: { $0.name == parameters.name }) else {
            throw ToolError.unknownTool(parameters.name)
        }
        let arguments = Arguments(parameters.arguments, calendar: calendar)
        try arguments.refuseUnknown(
            tool: tool.name,
            allowed: Array((tool.inputSchema.objectValue?["properties"]?.objectValue ?? [:]).keys))

        if parameters.name == ToolCatalog.mediaViewName {
            let availability = store.availability()
            guard availability.isUsable else { throw ToolError.storeUnavailable(availability) }
            return try await mediaView(arguments)
        }
        return [.text(try await run(parameters.name, arguments))]
    }

    private func run(_ name: String, _ arguments: Arguments) async throws -> String {
        // Answered before the availability check: "why can nothing be read" is exactly the
        // question asked when the database is missing or the wrong shape.
        if name == ToolCatalog.statusName {
            return format.status(
                store.databaseInfo(), availability: store.availability(),
                binaryPath: Self.binaryPath)
        }

        // Before the chat-store check on purpose: db_* is how a broken chat store gets
        // diagnosed, and it reads other databases that may be perfectly fine.
        switch name {
        case ToolCatalog.dbTablesName, ToolCatalog.dbSchemaName, ToolCatalog.dbQueryName:
            return try databaseTool(name, arguments)
        // By path it needs no chat store at all, and by message id the store raises its own
        // error, so the availability check above would only hide the reason.
        case ToolCatalog.audioTranscribeName:
            return try await audioTranscribe(arguments)

        case ToolCatalog.callsName, ToolCatalog.locationSharingName, ToolCatalog.labelsName,
            ToolCatalog.addressBookName, ToolCatalog.lidLookupName, ToolCatalog.channelsName:
            return try domainTool(name, arguments)
        default:
            break
        }

        let availability = store.availability()
        guard availability.isUsable else { throw ToolError.storeUnavailable(availability) }

        switch name {
        case ToolCatalog.chatsName: return try await chats(arguments)
        case ToolCatalog.chatGetName: return try await chat(arguments)
        case ToolCatalog.searchName: return try await search(arguments)
        case ToolCatalog.messageGetName: return try await message(arguments)
        case ToolCatalog.mediaName: return try await media(arguments)
        case ToolCatalog.groupGetName: return try await group(arguments)
        case ToolCatalog.mediaGetName: return try await mediaGet(arguments)
        default: throw ToolError.unknownTool(name)
        }
    }

    // MARK: Reads

    private func chats(_ arguments: Arguments) async throws -> String {
        var query = ChatQuery()
        query.name = try arguments.optionalString("name")
        query.kinds = try arguments.chatKinds("kinds")
        query.includeArchived = try arguments.bool("include_archived")
        query.includeHidden = try arguments.bool("include_hidden")
        (query.limit, query.offset) = try arguments.page(
            defaultLimit: Configuration.defaultLimit, limits: Configuration.limitRange)

        return format.chats(
            try await store.chats(matching: query), query: query, notices: arguments.notices)
    }

    private func chat(_ arguments: Arguments) async throws -> String {
        let id = try arguments.requiredIdentifier("chat_id", in: Configuration.identifierRange)
        var query = try messageQuery(arguments)
        guard let summary = try await store.chat(id: id) else {
            throw ToolError.chatNotFound(id: id)
        }
        query.chatID = id

        return format.chatPage(
            try await store.messages(matching: query), chat: summary, query: query,
            notices: arguments.notices)
    }

    private func search(_ arguments: Arguments) async throws -> String {
        var query = try messageQuery(arguments)
        query.chatID = try arguments.optionalIdentifier("chat_id", in: Configuration.identifierRange)
        query.text = try arguments.optionalString("query")
        // Without a phrase this would be "every message", which is chat_get's job. Starred
        // messages are the one list across chats that has no other tool.
        guard query.text != nil || query.starredOnly else {
            throw ToolError.badArgument(
                name: "query",
                reason: "give a phrase to find, or starred_only=true to list starred messages in every chat")
        }

        return format.searchResults(
            try await store.messages(matching: query), query: query, notices: arguments.notices)
    }

    private func message(_ arguments: Arguments) async throws -> String {
        let id = try arguments.requiredIdentifier("message_id", in: Configuration.identifierRange)
        let window = try arguments.window()
        guard let message = try await store.message(id: id) else {
            throw ToolError.messageNotFound(id: id)
        }
        return format.messageDetail(
            message, characterOffset: window.characterOffset, maxCharacters: window.maxCharacters,
            notices: arguments.notices)
    }

    private func media(_ arguments: Arguments) async throws -> String {
        var query = try messageQuery(arguments)
        query.chatID = try arguments.optionalIdentifier("chat_id", in: Configuration.identifierRange)
        let requestedKinds = try arguments.mediaKinds("kinds")
        // WhatsApp attaches a ZWAMEDIAITEM row to an ordinary text message for a link
        // preview's thumbnail, so "has a media row" is not the same question as "is an
        // attachment". An empty "kinds" argument therefore means every kind this tool
        // covers, never "no filter" — the empty-means-everything convention chat_get uses
        // would let those text messages through dressed as attachments.
        query.kinds = requestedKinds.isEmpty ? MediaKind.allCases : requestedKinds

        return format.media(
            try await store.media(matching: query), query: query, notices: arguments.notices)
    }

    private func group(_ arguments: Arguments) async throws -> String {
        let id = try arguments.requiredIdentifier("chat_id", in: Configuration.identifierRange)
        let page = try arguments.page(
            defaultLimit: Configuration.defaultLimit, limits: Configuration.limitRange)
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
        return format.group(
            group, chat: summary, limit: page.limit, offset: page.offset,
            notices: arguments.notices)
    }

    // MARK: Attachment files

    /// The message, its attachment, and the file's resolved URL when it is on this Mac.
    private func attachment(id: Int64) async throws -> (
        message: Message, attachment: Attachment, url: URL?
    ) {
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

    private func audioTranscribe(_ arguments: Arguments) async throws -> String {
        guard let transcription else {
            throw ToolError.mediaProblem("Transcription is not configured in this server.")
        }
        let messageID = try arguments.optionalIdentifier(
            "message_id", in: Configuration.identifierRange)
        let path = try arguments.optionalString("path")
        let language = try arguments.requiredString("language")
        let window = try arguments.window()
        guard (messageID == nil) != (path == nil) else {
            throw ToolError.badArgument(
                name: "message_id", reason: "give exactly one of 'message_id' and 'path'")
        }

        var heading: String?
        var clips = ClippedFields()
        let url: URL
        if let path {
            guard let resolved = mediaFiles?.contained(path) else {
                throw ToolError.mediaProblem(
                    "That path is not a file inside WhatsApp's Message folder, so it is not opened.")
            }
            url = resolved
        } else {
            let (message, attachment, resolved) = try await attachment(id: messageID ?? 0)
            guard [.voiceNote, .audioFile, .video].contains(attachment.kind) else {
                throw ToolError.mediaProblem(
                    "Message \(message.id) is a \(MediaKind(attachment.kind).rawValue), which has no sound to transcribe.")
            }
            guard let resolved else {
                return format.mediaMissing(message, attachment: attachment, notices: arguments.notices)
            }
            heading = format.mediaHeading(message, attachment: attachment, clips: &clips)
            url = resolved
        }

        do {
            let result = try await transcription.transcribe(file: url, language: language)
            return format.transcription(
                result, heading: heading, characterOffset: window.characterOffset,
                maxCharacters: window.maxCharacters,
                notices: arguments.notices + clips.notices(tool: ToolCatalog.messageGetName))
        } catch let failure as TranscriptionError {
            throw ToolError.mediaProblem(failure.message)
        } catch MediaFiles.ViewError.accessDenied(let path) {
            throw ToolError.accessDenied(path)
        } catch let failure as MediaFiles.ViewError {
            throw ToolError.mediaProblem("The file could not be opened: \(failure).")
        }
    }

    private func mediaGet(_ arguments: Arguments) async throws -> String {
        let id = try arguments.requiredIdentifier("message_id", in: Configuration.identifierRange)
        let (message, attachment, url) = try await attachment(id: id)
        guard let url else {
            return format.mediaMissing(message, attachment: attachment, notices: arguments.notices)
        }
        do {
            return format.mediaFacts(
                message, attachment: attachment, url: url, facts: try MediaFiles.facts(of: url),
                notices: arguments.notices)
        } catch MediaFiles.ViewError.accessDenied(let path) {
            throw ToolError.accessDenied(path)
        } catch {
            throw ToolError.mediaProblem("The file could not be read: \(error.localizedDescription)")
        }
    }

    private func mediaView(_ arguments: Arguments) async throws -> [ToolOutput.Block] {
        let id = try arguments.requiredIdentifier("message_id", in: Configuration.identifierRange)
        let frames = try arguments.int(
            "frames", default: Configuration.defaultFrames, in: Configuration.frameRange)
        let language = try arguments.optionalString("language")
        let window = try arguments.window()
        let firstPage = try arguments.int("first_page", default: 1, in: Configuration.pageNumberRange)
        let lastPage = try arguments.int(
            "last_page", default: Configuration.pageNumberRange.upperBound,
            in: Configuration.pageNumberRange)
        guard lastPage >= firstPage else {
            throw ToolError.badArgument(
                name: "last_page", reason: "it is before first_page; pages run from first_page to last_page")
        }

        let (message, attachment, url) = try await attachment(id: id)
        guard let url else {
            return [.text(format.mediaMissing(message, attachment: attachment, notices: arguments.notices))]
        }

        var clips = ClippedFields()
        let heading = format.mediaHeading(message, attachment: attachment, clips: &clips)
        var notices: [String] { arguments.notices + clips.notices(tool: ToolCatalog.messageGetName) }
        do {
            switch attachment.kind {
            case .photo, .sticker, .gif:
                let jpeg = try MediaFiles.jpegData(of: url)
                return [
                    .text(ToolStandard.withNotices(notices, heading)),
                    .image(data: jpeg.base64EncodedString(), mimeType: "image/jpeg"),
                ]

            case .video:
                let (images, seconds) = try await MediaFiles.keyFrames(of: url, count: frames)
                // Best effort and only when asked: the frames are the answer and the sound is
                // an addition, so anything that goes wrong here is a note and never a failure.
                // No language means no transcript, because macOS cannot detect one.
                var transcript: Transcription?
                var missingTranscript =
                    "No transcript: pass 'language' (for example es-ES), or use audio_transcribe."
                if let language, let transcription {
                    do {
                        transcript = try await transcription.transcribe(file: url, language: language)
                    } catch let failure as TranscriptionError {
                        missingTranscript =
                            "No transcript: "
                            + (failure.message.split(separator: "\n").first.map(String.init) ?? "unavailable")
                    } catch {
                        missingTranscript = "No transcript: the sound could not be read."
                    }
                }
                let summary = ToolStandard.fitting(window.maxCharacters) { size in
                    var lines = [
                        heading,
                        "\(images.count) frames, evenly spaced over \(Int(seconds.rounded())) s. "
                            + "Pass frames (up to \(Configuration.frameRange.upperBound)) for more.",
                    ]
                    var all = notices
                    if let transcript {
                        let part = format.transcriptWindow(
                            transcript, characterOffset: window.characterOffset, maxCharacters: size)
                        lines += ["", part.text]
                        if let notice = part.notice { all.append(notice) }
                    } else {
                        lines.append(missingTranscript)
                    }
                    return ToolStandard.withNotices(all, lines.joined(separator: "\n"))
                }
                return [.text(summary)]
                    + images.map { .image(data: $0.base64EncodedString(), mimeType: "image/jpeg") }

            case .document:
                let mime = MediaFiles.mimeType(of: url)
                if mime == "application/pdf" {
                    let document = try MediaFiles.pdfText(of: url, firstPage: firstPage, lastPage: lastPage)
                    return [
                        .text(
                            format.documentText(
                                document, pdf: true, heading: heading,
                                characterOffset: window.characterOffset,
                                maxCharacters: window.maxCharacters, notices: notices))
                    ]
                }
                if mime.hasPrefix("text/") {
                    return [
                        .text(
                            format.documentText(
                                try MediaFiles.plainText(of: url), pdf: false, heading: heading,
                                characterOffset: window.characterOffset,
                                maxCharacters: window.maxCharacters, notices: notices))
                    ]
                }
                return [
                    .text(
                        ToolStandard.withNotices(
                            notices,
                            heading + "\n\nNo viewer for \(mime): this server reads images, PDFs, text "
                                + "and video frames. media_get gives the path and hash."))
                ]

            case .voiceNote, .audioFile:
                return [
                    .text(
                        ToolStandard.withNotices(
                            notices,
                            heading + "\n\nAudio is not played here. Use audio_transcribe with this message id."))
                ]
            }
        } catch let failure as MediaFiles.ViewError {
            switch failure {
            case .accessDenied(let path):
                throw ToolError.accessDenied(path)
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
            case .pastLastPage(let first, let count):
                throw ToolError.badArgument(
                    name: "first_page",
                    reason: "this PDF has \(count) page(s), so first_page=\(first) is past its end")
            }
        }
    }

    // MARK: Beyond the chat store

    private func domainTool(_ name: String, _ arguments: Arguments) throws -> String {
        guard let reader else { throw ToolError.explorerUnavailable }
        do {
            switch name {
            case ToolCatalog.callsName:
                var query = CallQuery()
                (query.from, query.before) = try arguments.dateRange()
                query.newestFirst = try arguments.newestFirst()
                (query.limit, query.offset) = try arguments.page(
                    defaultLimit: Configuration.defaultLimit, limits: Configuration.limitRange)
                let (calls, total, source) = try reader.calls(matching: query)
                return format.calls(
                    calls, total: total, source: source, offset: query.offset,
                    notices: arguments.notices)

            case ToolCatalog.locationSharingName:
                let page = try arguments.page(
                    defaultLimit: Configuration.defaultLimit, limits: Configuration.limitRange)
                let (sharing, source) = try reader.locationSharing(
                    limit: page.limit, offset: page.offset)
                return format.locationSharing(
                    sharing, source: source, offset: page.offset, notices: arguments.notices)

            case ToolCatalog.labelsName:
                let labelID = try arguments.optionalIdentifier(
                    "label_id", in: Configuration.labelIdentifierRange)
                let page = try arguments.page(
                    defaultLimit: Configuration.defaultLimit, limits: Configuration.limitRange)
                if let id = labelID {
                    let (label, entities, total, source) = try reader.labeledEntities(
                        labelID: id, limit: page.limit, offset: page.offset)
                    guard let label else {
                        throw ToolError.badArgument(
                            name: "label_id", reason: "no label has id \(id); call labels_list without it")
                    }
                    return format.labeledEntities(
                        entities, total: total, label: label, source: source, offset: page.offset,
                        notices: arguments.notices)
                }
                let (labels, source) = try reader.labels()
                return format.labels(
                    labels, source: source, limit: page.limit, offset: page.offset,
                    notices: arguments.notices)

            case ToolCatalog.addressBookName:
                var query = AddressBookQuery()
                query.name = try arguments.optionalString("name")
                (query.limit, query.offset) = try arguments.page(
                    defaultLimit: Configuration.defaultLimit, limits: Configuration.limitRange)
                let (entries, total, source) = try reader.addressBook(matching: query)
                return format.addressBook(
                    entries, total: total, source: source, offset: query.offset,
                    notices: arguments.notices)

            case ToolCatalog.lidLookupName:
                let value = try arguments.requiredString("value")
                let page = try arguments.page(
                    defaultLimit: Configuration.defaultLimit, limits: Configuration.limitRange)
                let (matches, sources, notes) = try reader.lidLookup(value)
                return format.lidMatches(
                    matches, value: value, sources: sources, notes: notes, limit: page.limit,
                    offset: page.offset, notices: arguments.notices)

            default:
                let channelName = try arguments.optionalString("name")
                let page = try arguments.page(
                    defaultLimit: Configuration.defaultLimit, limits: Configuration.limitRange)
                let (channels, total, source) = try reader.channels(
                    name: channelName, limit: page.limit, offset: page.offset)
                return format.channels(
                    channels, total: total, source: source, offset: page.offset,
                    notices: arguments.notices)
            }
        } catch let failure as SourceError {
            throw failure.toolError
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
                let page = try arguments.page(
                    defaultLimit: Configuration.defaultTableLimit, limits: Configuration.tableLimitRange)
                let (entries, source) = try explorer.tables(in: database)
                return format.databaseTables(
                    entries, source: source, limit: page.limit, offset: page.offset,
                    notices: arguments.notices)

            case ToolCatalog.dbSchemaName:
                let table = try arguments.optionalString("table")
                let page = try arguments.page(
                    defaultLimit: Configuration.defaultSchemaLimit, limits: Configuration.schemaLimitRange)
                let (statements, source) = try explorer.schema(of: database, table: table)
                return format.databaseSchema(
                    statements, source: source, limit: page.limit, offset: page.offset,
                    notices: arguments.notices)

            default:
                let sql = try arguments.requiredString("sql")
                let page = try arguments.page(
                    defaultLimit: Configuration.defaultQueryLimit, limits: Configuration.queryLimitRange)
                let result = try explorer.select(
                    sql, in: database, limit: page.limit, offset: page.offset,
                    maxCharacters: arguments.isGiven("limit")
                        ? Configuration.longestQueryCharacters : Configuration.queryCharacters)
                return format.queryResult(result, offset: page.offset, notices: arguments.notices)
            }
        } catch let refusal as ReadOnlyDatabase.SelectRefusal {
            throw ToolError.queryRefused(refusal.detail)
        } catch let failure as SourceError {
            throw failure.toolError
        } catch let failure as ReadOnlyDatabase.QueryFailure {
            throw ToolError.storeFailure(failure.detail)
        }
    }

    /// The filters `chat_get`, `whatsapp_search` and `media_list` share.
    ///
    /// Each mirrors a column the store already holds. Nothing here is derived, ranked or
    /// scored: the rows go up as they are and the reading of them happens above.
    private func messageQuery(_ arguments: Arguments) throws -> MessageQuery {
        var query = MessageQuery()
        (query.from, query.before) = try arguments.dateRange()
        query.fromMe = try arguments.optionalBool("from_me")
        query.starredOnly = try arguments.bool("starred_only")
        query.newestFirst = try arguments.newestFirst()
        (query.limit, query.offset) = try arguments.page(
            defaultLimit: Configuration.defaultMessageLimit, limits: Configuration.messageLimitRange)
        return query
    }

    static var binaryPath: String {
        CommandLine.arguments.first.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? "(unknown)"
    }
}
