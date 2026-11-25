import Foundation

/// Renders answers as text.
///
/// Formatting only. Nothing here decides what may be read — that lives in `Dispatch` —
/// and nothing here computes a ranking, a score or a summary of what the rows mean. The
/// rows go up as they are, because reading them is the caller's job.
///
/// `chat_get`, `whatsapp_search` and `media_list` all render through `messageLine`. One
/// function is what keeps them from drifting: three renderers meant a photo could be
/// described one way in a conversation and another way in an attachment list, and a caller
/// had no way to tell the two apart from the output.
///
/// Every growing answer is rendered here the same way: the notices first (`Notice`, one
/// sentence a line), a blank line, then the data. A page is rendered inside
/// `ToolStandard.fitting`, so one whose rows are wider than ordinary holds fewer of them
/// and its notice says where to resume, instead of reaching the guard.
public struct Format: Sendable {
    private let calendar: Calendar

    public init(calendar: Calendar) {
        self.calendar = calendar
    }

    // MARK: Status

    public func status(
        _ info: DatabaseInfo, availability: StoreAvailability, binaryPath: String
    ) -> String {
        var lines = ["whatsapp-mcp \(WhatsAppMCPServer.version)"]
        lines.append("binary: \(binaryPath)")
        lines.append("")

        lines.append("READ · WhatsApp's local chat database")
        lines.append("  path: \(info.path)")
        switch availability {
        case .ready:
            lines.append("  status: readable")
        case .databaseMissing:
            lines.append("  status: NOT FOUND — is WhatsApp for Mac installed and signed in?")
        case .accessDenied:
            lines.append(
                "  status: ACCESS DENIED — the file is there but macOS refused to open it")
        case .databaseUnreadable(_, let detail):
            lines.append("  status: UNREADABLE — \(detail)")
        case .schemaUnexpected(let missing):
            lines.append("  status: UNEXPECTED SHAPE — missing \(missing.joined(separator: ", "))")
        }
        if let size = info.size {
            lines.append("  size: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
        }
        if let modified = info.modified {
            lines.append("  last written: \(DateParsing.roundTrip(modified, calendar: calendar))")
        }
        // Worth stating plainly: this server opens the file read-only, through its
        // write-ahead log, so it never writes a message and the newest ones are included.
        lines.append("  opened: read-only, through the write-ahead log — this server can never write to it")
        if let wal = info.walBytes, wal > 0 {
            lines.append("  write-ahead log: \(wal) bytes, read on every call")
        }
        if let chats = info.chatCount { lines.append("  chats: \(chats)") }
        if let messages = info.messageCount { lines.append("  messages: \(messages)") }
        // A table this server reads when it is there. Named so an absent one reads as a
        // feature that is off in this WhatsApp version, not as data that does not exist.
        if !info.absentOptionalTables.isEmpty {
            lines.append(
                "  reduced: this WhatsApp version has no "
                    + info.absentOptionalTables.joined(separator: ", ")
                    + " — those fields come back empty")
        }
        switch availability {
        case .accessDenied:
            lines.append("  permission: DENIED by macOS — this server's program needs Full Disk Access:")
            lines.append("    System Settings → Privacy & Security → Full Disk Access, turn on the")
            lines.append("    program on the `binary:` line above (or add it with +; if Claude Code or a")
            lines.append("    terminal starts the server, that program instead), then quit and reopen the")
            lines.append("    app that starts the server. An ad-hoc rebuild or update is a new program: grant it again.")
        case .ready:
            lines.append("  permission: macOS allowed this server to read it")
        case .databaseMissing, .databaseUnreadable, .schemaUnexpected:
            lines.append("  permission: not the problem shown above (macOS did not refuse the read)")
        }

        lines.append("")
        lines.append("OTHER DATABASES · db_tables, db_schema, db_query and the call, label, address")
        lines.append("  book, LID and channel tools read WhatsApp's other databases live, the same way;")
        lines.append("  nothing is copied or kept. Each answer names the database and when it was read.")

        lines.append("")
        lines.append("This server never changes WhatsApp's data. It has no tool that sends, edits or")
        lines.append("deletes anything, and no way to reach any network. Reading a database does update")
        lines.append("its -shm index file, which SQLite uses to coordinate readers; it holds no messages.")
        lines.append("It keeps nothing: the only file it makes is a scratch folder for audio conversion,")
        lines.append("in ~/Library/Caches/whatsapp-mcp, deleted when the call ends.")

        // Things a caller will otherwise assume are merely missing from this server,
        // rather than absent from WhatsApp's own storage. Every one was established by
        // checking each table and column name in the schema.
        lines.append("")
        lines.append("NOT IN THIS DATABASE · things WhatsApp does not store locally")
        lines.append("  no LID→phone mapping in the chat database: a …@lid sender with no profile name stays "
                    + "a LID there. lid_lookup reads separate pairing tables whose coverage is not measured")
        lines.append("  no disappearing-message setting or TTL, per chat or per message")
        lines.append("  no recoverable text for a deleted message, and no link to what it replaced")
        lines.append("  no meaning for a delivery code: the number is stored, the wording is not")
        lines.append("  no record of who starred a message or when: a star is a yes/no flag on the message")

        return lines.joined(separator: "\n")
    }

    // MARK: Raw databases

    func sourceLine(_ source: SourceInfo) -> String {
        "\(source.database.rawValue) · read live \(DateParsing.roundTrip(source.readAt, calendar: calendar))"
    }

    public func databaseTables(
        _ entries: [TableEntry], source: SourceInfo, limit: Int, offset: Int, notices: [String]
    ) -> String {
        let page = Array(entries.dropFirst(offset).prefix(limit))
        return sourcePage(
            page, offset: offset, total: entries.count, things: "tables and views",
            notices: notices, heading: [sourceLine(source), "\(entries.count) tables and views", ""],
            empty: "This database declares no tables or views."
        ) { entry, _ in "\(entry.name)  [\(entry.kind)]" }
    }

    /// One CREATE statement a row, never cut inside: a statement is the unit a caller can
    /// read, and a half of one is not valid SQL.
    public func databaseSchema(
        _ statements: [String], source: SourceInfo, limit: Int, offset: Int, notices: [String]
    ) -> String {
        let page = Array(statements.dropFirst(offset).prefix(limit))
        return sourcePage(
            page, offset: offset, total: statements.count, things: "statements",
            notices: notices, heading: [sourceLine(source), ""],
            empty: "No such table or view in this database."
        ) { statement, _ in statement + ";" }
    }

    /// Tab-separated, because a SQL value can contain a comma and cannot contain a tab
    /// without it being visible. A tab or newline inside a value is replaced by a space
    /// so one row is always one line.
    ///
    /// The statement's total is not known without running it twice, so a page that does
    /// not end the rows says only that more exist.
    public func queryResult(_ result: QueryResult, offset: Int, notices: [String]) -> String {
        ToolStandard.fitting(result.rows.count) { size in
            let rows = Array(result.rows.prefix(size))
            let more = result.moreRowsExist || rows.count < result.rows.count
            let total: Int? = more ? nil : (rows.isEmpty ? result.rowsSkipped : offset + rows.count)
            var all = notices
            if let position = Notice.page(offset: offset, count: rows.count, total: total, things: "rows") {
                all.append(position)
            }
            if result.clippedCells {
                all.append(
                    Notice.clipped(
                        field: "Every value", width: result.cellWidth,
                        tool: "db_query, selecting substr(column, start, length)"))
            }
            var lines = [sourceLine(result.source)]
            lines.append("\(rows.count) row\(rows.count == 1 ? "" : "s")")
            lines.append("")
            lines.append(result.columns.joined(separator: "\t"))
            for row in rows {
                lines.append(row.map { $0.displaySafe }.joined(separator: "\t"))
            }
            return ToolStandard.withNotices(all, lines.joined(separator: "\n"))
        }
    }

    // MARK: Attachment files

    private func sender(_ message: Message) -> String {
        if message.isFromMe { return "you" }
        return message.sender?.displayName ?? message.chatName
    }

    /// The line that names an attachment's message, with its caption shortened to
    /// `Configuration.textWidth`; the notice that says so is in `clips`.
    public func mediaHeading(
        _ message: Message, attachment: Attachment, clips: inout ClippedFields
    ) -> String {
        "message \(message.id) · \(MediaKind(attachment.kind).rawValue) · chat \(message.chatName) · "
            + "from \(sender(message)) · \(DateParsing.roundTrip(message.date, calendar: calendar))"
            + (message.text.map {
                "\ncaption: "
                    + clips.clip(
                        $0.replacingOccurrences(of: "\n", with: " ⏎ ").displaySafe,
                        to: Configuration.textWidth, field: "Caption")
            } ?? "")
    }

    public func mediaMissing(_ message: Message, attachment: Attachment, notices: [String]) -> String {
        var clips = ClippedFields()
        let heading = mediaHeading(message, attachment: attachment, clips: &clips)
        return ToolStandard.withNotices(
            notices + clips.notices(tool: ToolCatalog.messageGetName),
            heading
                + "\n\nThe file is not on this Mac. WhatsApp keeps the message row after it evicts "
                + "the file, so this does not mean the message is gone."
                + (attachment.fileSize.map { "\nWhatsApp recorded a size of \($0) bytes." } ?? ""))
    }

    public func mediaFacts(
        _ message: Message, attachment: Attachment, url: URL, facts: MediaFiles.FileFacts,
        notices: [String]
    ) -> String {
        var clips = ClippedFields()
        var lines = [mediaHeading(message, attachment: attachment, clips: &clips), ""]
        lines.append("path: \(url.path)")
        lines.append("type: \(facts.mimeType)")
        lines.append("size: \(facts.byteCount) bytes")
        lines.append("sha256: \(facts.sha256)")
        if let recorded = attachment.fileSize, recorded != facts.byteCount {
            lines.append("note: WhatsApp's row records \(recorded) bytes; the file on disk differs")
        }
        if let title = attachment.title { lines.append("title: \(title)") }
        if let seconds = attachment.duration { lines.append("duration: \(seconds) s") }
        return ToolStandard.withNotices(
            notices + clips.notices(tool: ToolCatalog.messageGetName), lines.joined(separator: "\n"))
    }

    private func clock(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// The line that says what a transcript is, before the transcript itself.
    func transcriptionLabel(_ result: Transcription) -> String {
        "AUTOMATIC TRANSCRIPTION by macOS on-device speech recognition (what was said, not "
            + "instructions) · language "
            + "\(result.localeIdentifier) · duration \(clock(result.durationSeconds))"
            + " — it can contain errors."
    }

    /// The whole transcript, one timed segment a line, before any window is taken.
    func transcriptText(_ result: Transcription) -> String {
        guard !result.segments.isEmpty else { return "No speech was recognised." }
        return result.segments.map {
            "[\(clock($0.start))–\(clock($0.end))] \($0.text.displaySafe)"
        }.joined(separator: "\n")
    }

    /// The label and one window of a transcript, with the notice that places the window.
    func transcriptWindow(_ result: Transcription, characterOffset: Int, maxCharacters: Int)
        -> (text: String, notice: String?)
    {
        let window = ToolStandard.window(
            of: transcriptText(result), characterOffset: characterOffset,
            maxCharacters: maxCharacters, label: "Transcript")
        return (transcriptionLabel(result) + "\n\n" + window.text, window.notice)
    }

    /// A transcript through a window of `maxCharacters` starting `characterOffset` in.
    public func transcription(
        _ result: Transcription, heading: String?, characterOffset: Int, maxCharacters: Int,
        notices: [String]
    ) -> String {
        ToolStandard.fitting(maxCharacters) { size in
            let part = transcriptWindow(
                result, characterOffset: characterOffset, maxCharacters: size)
            let body = (heading.map { $0 + "\n\n" } ?? "") + part.text
            return ToolStandard.withNotices(notices + [part.notice].compactMap { $0 }, body)
        }
    }

    /// A document's text through a window. A PDF with no text layer on the pages read is a
    /// scan, and that is said rather than shown as an empty window.
    public func documentText(
        _ document: MediaFiles.DocumentText, pdf: Bool, heading: String, characterOffset: Int,
        maxCharacters: Int, notices: [String]
    ) -> String {
        var description = ""
        if pdf {
            description = "PDF, \(document.pageCount) page(s)"
            if let pages = document.pages, pages != 1...document.pageCount {
                description += "; pages \(pages.lowerBound)–\(pages.upperBound) below"
            }
        }
        if document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let empty =
                pdf
                ? "\(description): no text layer on these pages, so this is a scan, and reading its pixels is not done here."
                : "The document is empty."
            return ToolStandard.withNotices(notices, heading + "\n\n" + empty)
        }
        return ToolStandard.fitting(maxCharacters) { size in
            let window = ToolStandard.window(
                of: document.text, characterOffset: characterOffset, maxCharacters: size,
                label: "Document text")
            let body = (pdf ? [heading, "", description, "", window.text] : [heading, "", window.text])
            return ToolStandard.withNotices(
                notices + [window.notice].compactMap { $0 }, body.joined(separator: "\n"))
        }
    }

    // MARK: Beyond the chat store

    private func when(_ date: Date?) -> String {
        date.map { DateParsing.roundTrip($0, calendar: calendar) } ?? "unknown time"
    }

    /// One page of rows the source already cut, or of every row when `rows` is a slice of
    /// them: the notices, the sentence that places the page in the whole, one sentence for
    /// each field a row shortened, then `heading` and the rows. `total` counts every match.
    func sourcePage<Row>(
        _ rows: [Row], offset: Int, total: Int, things: String, notices: [String],
        heading: [String], empty: String, clipTool: String = ToolCatalog.messageGetName,
        line: (Row, inout ClippedFields) -> String
    ) -> String {
        ToolStandard.fitting(rows.count) { size in
            let shown = Array(rows.prefix(size))
            var clips = ClippedFields()
            let lines = shown.map { line($0, &clips) }
            let position = Notice.page(offset: offset, count: shown.count, total: total, things: things)
            let all = notices + [position].compactMap { $0 } + clips.notices(tool: clipTool)
            let body = total == 0 ? heading + [empty] : heading + lines
            return ToolStandard.withNotices(all, body.joined(separator: "\n"))
        }
    }

    private static func plural(_ count: Int, _ one: String, _ many: String) -> String {
        "\(count) \(count == 1 ? one : many)"
    }

    public func calls(
        _ calls: [CallEvent], total: Int, source: SourceInfo, offset: Int, notices: [String]
    ) -> String {
        sourcePage(
            calls, offset: offset, total: total, things: "calls", notices: notices,
            heading: [sourceLine(source), Self.plural(total, "call", "calls"), ""],
            empty: "No calls found.",
            clipTool: "db_query (CallHistory, ZWACDCALLEVENTPARTICIPANT)"
        ) { call, clips in
            var parts = ["\(call.id)  \(when(call.date))"]
            if let incoming = call.incoming { parts.append(incoming ? "incoming" : "outgoing") }
            if let video = call.video { parts.append(video ? "video" : "voice") }
            if call.missed == true { parts.append("missed") }
            if let seconds = call.durationSeconds {
                parts.append("duration \(Int(seconds.rounded()))s")
            }
            if let code = call.outcomeCode { parts.append("outcome code \(code)") }
            if let code = call.missedReasonCode, call.missed == true {
                parts.append("missed-reason code \(code)")
            }
            if let group = call.groupJID { parts.append("group \(group)") }
            if let creator = call.creatorJID { parts.append("started by \(creator)") }
            if !call.participants.isEmpty {
                parts.append(
                    "with "
                        + clips.clip(
                            call.participants.map(\.jid).joined(separator: ", "),
                            to: Configuration.participantsWidth, field: "Participants"))
            }
            return parts.joined(separator: " · ")
        }
    }

    private enum SharingRow {
        case outgoing(LocationSharing.Outgoing)
        case recipient(LocationSharing.Recipient)
    }

    public func locationSharing(
        _ sharing: LocationSharing, source: SourceInfo, offset: Int, notices: [String]
    ) -> String {
        let rows = sharing.outgoing.map(SharingRow.outgoing) + sharing.recipients.map(SharingRow.recipient)
        return sourcePage(
            rows, offset: offset, total: sharing.outgoingTotal + sharing.recipientTotal,
            things: "sharing rows", notices: notices,
            heading: [
                sourceLine(source),
                "\(sharing.outgoingTotal) sharing session(s) you started, "
                    + "\(sharing.recipientTotal) recipient row(s) · sessions first, newest first, "
                    + "then recipients, latest expiry first",
                "",
            ],
            empty: "No live-location sharing recorded."
        ) { row, _ in
            switch row {
            case .outgoing(let item):
                return "shared in \(item.chat ?? "unknown chat") · from \(when(item.started)) · until "
                    + "\(when(item.ends))" + (item.participant.map { " · as \($0)" } ?? "")
            case .recipient(let item):
                return "recipient \(item.jid ?? "unknown") in \(item.chat ?? "unknown chat") · expires "
                    + when(item.expires)
            }
        }
    }

    public func labels(
        _ labels: [Label], source: SourceInfo, limit: Int, offset: Int, notices: [String]
    ) -> String {
        sourcePage(
            Array(labels.dropFirst(offset).prefix(limit)), offset: offset, total: labels.count,
            things: "labels", notices: notices,
            heading: [sourceLine(source), Self.plural(labels.count, "label", "labels"), ""],
            empty: "No labels. Labels exist only on accounts that use them."
        ) { label, _ in
            var line = "\(label.id)  \(label.name ?? "(unnamed)")"
            if let colour = label.colorID { line += " · colour id \(colour)" }
            if label.active == false { line += " · inactive" }
            line += " · \(label.labeledCount) labelled"
            return line
        }
    }

    public func labeledEntities(
        _ entities: [LabeledEntity], total: Int, label: Label, source: SourceInfo, offset: Int,
        notices: [String]
    ) -> String {
        sourcePage(
            entities, offset: offset, total: total, things: "labelled items", notices: notices,
            heading: [
                sourceLine(source),
                "Label \(label.id) \(label.name ?? "(unnamed)") · \(total) labelled · newest first", "",
            ],
            empty: "Nothing carries this label."
        ) { entity, _ in
            "\(entity.contactJID ?? entity.entityKey ?? "unknown")"
                + (entity.entityType.map { " · entity type \($0)" } ?? "")
                + " · \(when(entity.date))"
        }
    }

    public func addressBook(
        _ entries: [AddressBookEntry], total: Int, source: SourceInfo, offset: Int,
        notices: [String]
    ) -> String {
        sourcePage(
            entries, offset: offset, total: total, things: "entries", notices: notices,
            heading: [sourceLine(source), Self.plural(total, "entry", "entries") + " · by name", ""],
            empty: "No entries found."
        ) { entry, _ in
            var parts = ["\(entry.id)  \(entry.fullName ?? entry.businessName ?? "(no name)")"]
            if entry.fullName != nil, let business = entry.businessName { parts.append("business \(business)") }
            if let phone = entry.phoneNumber { parts.append("phone \(phone)") }
            if let lid = entry.lid { parts.append("lid \(lid)") }
            if let id = entry.whatsappID { parts.append("whatsapp id \(id)") }
            if let username = entry.username { parts.append("username \(username)") }
            if let about = entry.about { parts.append("about: \(about)") }
            return parts.joined(separator: " · ")
        }
    }

    public func lidMatches(
        _ matches: [LIDMatch], value: String, sources: [SourceInfo], notes: [String] = [],
        limit: Int, offset: Int, notices: [String]
    ) -> String {
        let heading =
            sources.map(sourceLine) + notes.map { "NOTE: \($0)" }
            + ["\(matches.count) record(s) for '\(ToolStandard.echo(value))'", ""]
        return sourcePage(
            Array(matches.dropFirst(offset).prefix(limit)), offset: offset, total: matches.count,
            things: "records", notices: notices, heading: heading,
            empty: "WhatsApp stored nothing for this value on this Mac. That is not proof that no "
                + "pairing exists: coverage of these tables has not been measured."
        ) { match, _ in
            var parts = [match.source]
            if let lid = match.lid { parts.append("lid \(lid)") }
            if let phone = match.phoneNumber { parts.append("phone \(phone)") }
            if let name = match.displayName { parts.append("name \(name)") }
            if let push = match.pushName { parts.append("push name \(push)") }
            if let username = match.username { parts.append("username \(username)") }
            return parts.joined(separator: " · ")
        }
    }

    public func channels(
        _ channels: [Channel], total: Int, source: SourceInfo, offset: Int, notices: [String]
    ) -> String {
        sourcePage(
            channels, offset: offset, total: total, things: "channels", notices: notices,
            heading: [sourceLine(source), Self.plural(total, "channel", "channels") + " · by name", ""],
            empty: "No channels found."
        ) { channel, _ in
            var line = "\(channel.name ?? "(unnamed)") · \(channel.jid)"
            if let by = channel.addedByName ?? channel.addedByLID { line += " · added by \(by)" }
            return line
        }
    }

    // MARK: Chats

    public func chats(_ page: ChatPage, query: ChatQuery, notices: [String]) -> String {
        var criteria: [String] = []
        if let name = query.name { criteria.append("name matching \"\(ToolStandard.echo(name))\"") }
        if !query.kinds.isEmpty {
            criteria.append(query.kinds.map(\.rawValue).joined(separator: "/"))
        }
        if query.includeArchived { criteria.append("including archived") }
        if query.includeHidden { criteria.append("including hidden") }
        let scope = criteria.isEmpty ? "" : " · \(criteria.joined(separator: " · "))"

        var held = notices
        if page.archivedNotShown > 0 {
            held.append(
                Notice.notShown(
                    count: page.archivedNotShown, things: "archived chats",
                    pass: "include_archived=true"))
        }
        if page.hiddenNotShown > 0 {
            held.append(
                Notice.notShown(
                    count: page.hiddenNotShown, things: "hidden chats", pass: "include_hidden=true"))
        }
        var footer = [""]
        if page.rows.contains(where: \.isPinned) {
            footer.append(
                "Pinned chats come first, as they do in WhatsApp, so this list is not "
                    + "purely newest-first. Their dates are real.")
            footer.append("")
        }
        footer.append("Use chat_get with an id from the first column.")

        let text = sourcePage(
            page.rows, offset: query.offset, total: page.total, things: "chats", notices: held,
            heading: [Self.plural(page.total, "chat", "chats") + scope + " · latest activity first", ""],
            empty: "No chats found."
        ) { chat, _ in
            var line = "\(chat.id)  \(chat.name)  [\(chat.kind.rawValue)]"
            if chat.isPinned { line += " (pinned)" }
            if chat.isArchived { line += " (archived)" }
            if chat.isHidden == true { line += " (hidden)" }
            if chat.unreadCount > 0 { line += " · \(chat.unreadCount) unread" }
            line += " · \(chat.messageCount) messages"
            if let date = chat.lastMessageDate {
                line += " · last \(DateParsing.roundTrip(date, calendar: calendar))"
            }
            return line
        }
        return page.rows.isEmpty ? text : text + "\n" + footer.joined(separator: "\n")
    }

    // MARK: Messages

    public func chatPage(
        _ page: MessagePage, chat: Chat, query: MessageQuery, notices: [String]
    ) -> String {
        var header = "\(chat.name) · id=\(chat.id) · \(page.total) matching"
        header += query.newestFirst ? " · newest first" : " · oldest first"
        return messagePage(
            page, query: query, notices: notices, heading: header, includingChat: false,
            empty: "No messages matched. Widen the range or drop a filter.")
    }

    public func searchResults(_ page: MessagePage, query: MessageQuery, notices: [String]) -> String {
        // The chat is named on every line here and on none in chat_get: there it is the
        // header, and repeating it down the page would say the same thing on every line.
        messagePage(
            page, query: query, notices: notices,
            heading: "\(page.total) matching · \(scope(of: query)) · \(order(query))",
            includingChat: true, empty: "No messages matched \(scope(of: query)).")
    }

    public func media(_ page: MessagePage, query: MessageQuery, notices: [String]) -> String {
        messagePage(
            page, query: query, notices: notices,
            heading: "\(page.total) shared · \(scope(of: query)) · \(order(query))",
            includingChat: query.chatID == nil, empty: "No attachments matched \(scope(of: query)).")
    }

    private func order(_ query: MessageQuery) -> String {
        query.newestFirst ? "newest first" : "oldest first"
    }

    /// The page the store cut, rendered through `fitting`: rows wider than ordinary make
    /// the page hold fewer, and the notice says where the next one starts.
    private func messagePage(
        _ page: MessagePage, query: MessageQuery, notices: [String], heading: String,
        includingChat: Bool, empty: String
    ) -> String {
        guard page.total > 0 else { return ToolStandard.withNotices(notices, empty) }
        return ToolStandard.fitting(page.rows.count) { size in
            let rows = Array(page.rows.prefix(size))
            var clips = ClippedFields()
            let lines = rows.map { messageLine($0, includingChat: includingChat, clips: &clips) }
            let position = Notice.page(
                offset: query.offset, count: rows.count, total: page.total, things: "messages")
            let all = notices + [position].compactMap { $0 } + clips.notices(tool: ToolCatalog.messageGetName)
            let body = [heading, ""] + lines + footnotes(for: rows)
            return ToolStandard.withNotices(all, body.joined(separator: "\n"))
        }
    }

    /// Everything the database holds about one message, on its own lines.
    ///
    /// The first line is the same line the other three tools print, so a caller can see it
    /// is looking at the row it asked for, and everything after it is what would not fit
    /// there.
    public func messageDetail(
        _ message: Message, characterOffset: Int, maxCharacters: Int, notices: [String]
    ) -> String {
        let whole = messageDetailText(message)
        return ToolStandard.fitting(maxCharacters) { size in
            let window = ToolStandard.window(
                of: whole, characterOffset: characterOffset, maxCharacters: size)
            return ToolStandard.withNotices(notices + [window.notice].compactMap { $0 }, window.text)
        }
    }

    func messageDetailText(_ message: Message) -> String {
        var whole = ClippedFields(clipping: false)
        var lines = [messageLine(message, includingChat: true, clips: &whole), ""]

        lines.append("chat: \(message.chatName) · id=\(message.chatID)")
        if let sender = message.sender {
            var line = "from: \(sender.displayName)  \(sender.jid)  [\(sender.kind.rawValue)]"
            if message.isFromMe { line += "  (you)" }
            lines.append(line)
            if let picture = sender.profilePicturePath {
                lines.append("profile picture: \(picture)")
            }
        } else if message.isFromMe {
            lines.append("from: you")
        }
        lines.append("date: \(DateParsing.roundTrip(message.date, calendar: calendar))")
        if let sent = message.sentDate {
            lines.append("sent: \(DateParsing.roundTrip(sent, calendar: calendar))")
        }
        if message.isStarred { lines.append("starred: yes") }

        if let text = message.text, !text.isEmpty {
            lines.append("")
            lines.append("text:")
            lines.append(text.quotedBlock)
        }
        if !message.mentions.isEmpty {
            lines.append("")
            lines.append("mentions:")
            for mention in message.mentions {
                lines.append("  \(mention.name ?? "(not named in this database)")  \(mention.jid)")
            }
        }

        if let quote = message.quote {
            lines.append("")
            var heading = "replies to:"
            if let id = quote.localMessageID {
                heading += " message \(id)"
            } else {
                heading += " a message that is not on this Mac"
            }
            if quote.quotedIsFromMe == true {
                heading += " (you)"
            } else if let author = quote.author {
                heading += " (\(author.displayName)  \(author.jid))"
            }
            lines.append(heading)
            if let text = quote.text, !text.isEmpty {
                lines.append(text.quotedBlock)
            } else {
                lines.append("  (the quote carries no words)")
            }
        }
        if !message.reactions.isEmpty {
            lines.append("")
            lines.append("reactions:")
            for reaction in message.reactions {
                var line = "  \(reaction.emoji)  "
                if let reactor = reaction.reactor {
                    line += "\(reactor.displayName)  \(reactor.jid)"
                } else {
                    line += "reactor not recorded in this entry"
                }
                if let date = reaction.date {
                    line += "  \(DateParsing.roundTrip(date, calendar: calendar))"
                }
                lines.append(line)
            }
        }

        lines.append("")
        lines.append(contentsOf: bodyDetail(message.body))

        lines.append("")
        // Reported as a number on purpose. See DeliveryState: the codes do not partition by
        // direction, so any mapping onto sent/delivered/read would be a guess about
        // somebody's behaviour.
        lines.append(
            "delivery code: \(message.delivery.rawCode) — this server has not established "
                + "what the codes mean and will not guess")
        if let error = message.delivery.errorCode {
            lines.append("error code: \(error) — WhatsApp recorded a failure on this message")
        }
        return lines.joined(separator: "\n")
    }

    private func bodyDetail(_ body: MessageBody) -> [String] {
        switch body {
        case .text:
            return ["body: text"]

        case .attachment(let attachment):
            var lines = ["body: \(attachment.kind.label)"]
            if let title = attachment.title { lines.append("filename: \(title)") }
            if let author = attachment.author { lines.append("author: \(author)") }
            if let size = attachment.fileSize {
                lines.append(
                    "size: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
            }
            if let duration = attachment.duration {
                lines.append("length: \(Self.clock(duration))")
            }
            if let path = attachment.localPath {
                lines.append("file: \(path)")
            } else {
                lines.append(
                    "file: not on this Mac — WhatsApp keeps the record after evicting the file")
            }
            if let remote = attachment.remoteURL {
                lines.append("whatsapp url: \(remote) — this server never fetches it")
            }
            return lines

        case .location(let coordinates):
            return [
                "body: location", "coordinates: \(coordinates.description)",
                "No place name: this server does no reverse geocoding, which would be a "
                    + "network call and a claim the database never made.",
            ]

        case .contactCard(let card):
            var lines = ["body: shared contact"]
            if let name = card.name { lines.append("name: \(name)") }
            if let vcard = card.vcard {
                lines.append("vcard:")
                lines.append(vcard.quotedBlock)
            }
            return lines

        case .link(let preview):
            var lines = ["body: link"]
            if let url = preview.url { lines.append("url: \(url)") }
            if let title = preview.title { lines.append("preview title: \(title)") }
            if let summary = preview.summary { lines.append("preview summary: \(summary)") }
            if preview.isEmpty {
                lines.append("WhatsApp stored no preview for it; the address is in the text.")
            }
            return lines

        case .groupEvent(let event):
            var lines = ["body: group event"]
            lines.append(
                "event code: \(event.code.map(String.init) ?? "none") — not decoded to a verb")
            lines.append("actor: \(event.actor.displayName)  \(event.actor.jid)")
            if let subject = event.subject {
                lines.append("subject: \(subject.displayName)  \(subject.jid)")
            } else {
                lines.append(
                    "subject: none — the database records the event without one, and there "
                        + "is no second source to recover it from")
            }
            return lines

        case .deletedForEveryone:
            return [
                "body: deleted for everyone",
                "The text is not recoverable and the message it replaced cannot be "
                    + "identified. WhatsApp clears the row in place and stores no link "
                    + "back to the original.",
            ]

        case .other(let typeCode):
            return [
                "body: WhatsApp type \(typeCode), which this server has no name for",
                "Reported by its number rather than forced into the nearest kind it "
                    + "resembles.",
            ]
        }
    }

    // MARK: Groups

    /// The group's own facts, then one page of its member rows, by address.
    public func group(_ group: Group, chat: Chat, limit: Int, offset: Int, notices: [String]) -> String {
        let members = group.members.sorted {
            ($0.identity.jid, $0.identity.displayName) < ($1.identity.jid, $1.identity.displayName)
        }
        var lines = [
            "\(chat.name) · id=\(chat.id) · \(group.members.count) member"
                + (group.members.count == 1 ? "" : "s")
        ]
        lines.append("")

        if let creator = group.creator {
            var line = "Created by \(creator.displayName)"
            if let created = group.creationDate {
                line += " on \(DateParsing.roundTrip(created, calendar: calendar))"
            }
            lines.append(line)
        } else if let created = group.creationDate {
            lines.append("Created \(DateParsing.roundTrip(created, calendar: calendar))")
        }
        if let subjectDate = group.subjectChangedDate {
            var line = "Name last changed \(DateParsing.roundTrip(subjectDate, calendar: calendar))"
            if let by = group.subjectChangedBy { line += " by \(by.displayName)" }
            lines.append(line)
        }
        if let picture = group.picturePath {
            lines.append("Icon: \(picture)")
        } else if let pictureID = group.pictureID {
            lines.append("Picture id: \(pictureID) — the file itself is not on this Mac")
        }

        lines.append("")
        // Stated inline, not only in the tool description, because a caller reading just
        // the rows below would otherwise take a missing member for somebody who left, and
        // an inactive one for somebody removed.
        lines.append(
            "This is every member row stored, not a list of who is in the group today: "
                + "rows flagged inactive are kept. What inactive means — left, removed, "
                + "something else — the database does not say.")
        lines.append("")
        lines.append("Members, by address:")
        lines.append("")

        return sourcePage(
            Array(members.dropFirst(offset).prefix(limit)), offset: offset, total: members.count,
            things: "members", notices: notices, heading: lines, empty: "(no member rows found)"
        ) { member, _ in
            var line = "\(member.identity.jid)  \(member.identity.displayName)"
            if member.isAdmin == true { line += "  (admin)" }
            if member.isActive == false { line += "  (inactive)" }
            return line
        }
    }

    // MARK: The shared message line

    /// One message, one line. The shape every list tool prints.
    ///
    /// A message that is not words says **what it was** — a photo, a sticker, a voice note
    /// with its length — because a message with no text is not an empty message, and the
    /// difference between a record and a gap is exactly that word.
    ///
    /// The fields other people write at any length (the text, a file name, a link and its
    /// title, the reactions) are shortened to their width in `Configuration`, and `clips`
    /// records which were, so the page says so once.
    func messageLine(_ message: Message, includingChat: Bool, clips: inout ClippedFields) -> String {
        var line = "\(message.id)  \(DateParsing.roundTrip(message.date, calendar: calendar))"
        if includingChat { line += "  \(message.chatName)" }

        // A group event carries no sender or body in the usual sense — the actor and
        // subject are the whole of it — so it gets its own layout rather than being
        // squeezed into "who: text" with a bare JID standing in for both.
        if case .groupEvent(let event) = message.body {
            line += "  [\(event.code.map { "group event \($0)" } ?? "group event")]"
            line += " \(event.actor.displayName)"
            if let subject = event.subject { line += " → \(subject.displayName)" }
            return line
        }

        // A group member WhatsApp has no name for is still worth identifying by address;
        // falling straight to the chat name would report every unknown sender as the group.
        let who = message.isFromMe ? "you" : (message.sender?.displayName ?? message.chatName)
        line += "  \(who):"

        switch message.body {
        case .text, .link:
            break
        case .attachment(let attachment):
            line += " [\(attachment.kind.label)"
            if let duration = attachment.duration { line += " \(Self.clock(duration))" }
            line += "]"
        case .location(let coordinates):
            line += " [location] \(coordinates.description)"
        case .contactCard(let card):
            line += " [contact]"
            if let name = card.name {
                line += " " + clips.clip(name, to: Configuration.titleWidth, field: "Contact name")
            }
        case .deletedForEveryone:
            line += " [deleted for everyone]"
        case .other(let typeCode):
            line += " [type \(typeCode)]"
        case .groupEvent:
            break  // Returned above.
        }

        if let text = message.text, !text.isEmpty {
            line +=
                " "
                + clips.clip(
                    text.replacingOccurrences(of: "\n", with: " ⏎ ").displaySafe,
                    to: Configuration.textWidth, field: "Text")
        }

        if case .attachment(let attachment) = message.body {
            if let title = attachment.title {
                line += "  " + clips.clip(title, to: Configuration.titleWidth, field: "Filename")
            }
            // Present means the file is genuinely here; absent is the ordinary case and is
            // explained once in the footnote rather than 50 times down the page.
            if let path = attachment.localPath { line += "  \(path)" }
        }
        if case .link(let preview) = message.body {
            if let url = preview.url {
                line += "  → " + clips.clip(url, to: Configuration.linkWidth, field: "Link")
            }
            if let title = preview.title {
                line += " — \"" + clips.clip(title, to: Configuration.titleWidth, field: "Link title") + "\""
            }
        }
        if let quote = message.quote {
            line += quote.localMessageID.map { "  ↩\($0)" } ?? "  ↩"
        }
        if !message.reactions.isEmpty {
            line +=
                "  ["
                + clips.clip(
                    message.reactions.map(\.emoji).joined(separator: " "),
                    to: Configuration.reactionsWidth, field: "Reactions")
                + "]"
        }
        if message.isStarred { line += "  ★" }
        return line
    }

    /// Explains a convention the lines above rely on, and only when they do.
    private func footnotes(for rows: [Message]) -> [String] {
        var notes: [String] = []
        let attachments = rows.compactMap { row -> Attachment? in
            if case .attachment(let attachment) = row.body { return attachment }
            return nil
        }
        if attachments.contains(where: { $0.localPath == nil }) {
            notes.append("")
            notes.append(
                "An attachment shown without a path is not on this Mac. WhatsApp evicts "
                    + "the file and keeps the record, so that is the ordinary case — the "
                    + "message itself is not gone.")
        }
        if rows.contains(where: { $0.quote != nil }) {
            notes.append("")
            notes.append(
                "↩N is a reply to message N of the same chat; ↩ alone is a reply whose "
                    + "original is not on this Mac. message_get shows the quoted words.")
        }
        if rows.contains(where: { !$0.reactions.isEmpty }) {
            notes.append("")
            notes.append("[😮 ❤️] lists the reactions on a message; message_get says who.")
        }
        return notes
    }

    private func scope(of query: MessageQuery) -> String {
        var criteria: [String] = []
        if let text = query.text { criteria.append("text \"\(ToolStandard.echo(text))\"") }
        if let chatID = query.chatID { criteria.append("in chat \(chatID)") }
        if !query.kinds.isEmpty {
            criteria.append(query.kinds.map(\.rawValue).joined(separator: "/"))
        }
        if let from = query.from {
            criteria.append("from \(DateParsing.roundTrip(from, calendar: calendar))")
        }
        if let before = query.before {
            criteria.append("before \(DateParsing.roundTrip(before, calendar: calendar))")
        }
        if let fromMe = query.fromMe { criteria.append(fromMe ? "sent by you" : "received") }
        if query.starredOnly { criteria.append("starred") }
        return criteria.isEmpty ? "every message" : criteria.joined(separator: " · ")
    }

    private static func clock(_ seconds: Int) -> String {
        "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

/// The fields a result shortened, each announced once, in the order first met.
public struct ClippedFields: Sendable {
    private var clipping: Bool
    private var fields: [(name: String, width: Int)] = []

    /// `clipping: false` shows every field whole: the detail of one message is where the
    /// rest is read.
    public init(clipping: Bool = true) {
        self.clipping = clipping
    }

    /// `text` at most `width` characters long, ending in "…" when it was cut.
    public mutating func clip(_ text: String, to width: Int, field: String) -> String {
        guard clipping, text.count > width else { return text }
        if !fields.contains(where: { $0.name == field }) { fields.append((field, width)) }
        return String(text.prefix(width - 1)) + "…"
    }

    public func notices(tool: String) -> [String] {
        fields.map { Notice.clipped(field: $0.name, width: $0.width, tool: tool) }
    }
}
