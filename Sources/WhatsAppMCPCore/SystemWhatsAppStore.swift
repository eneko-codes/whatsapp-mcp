import Foundation

/// The only type that opens WhatsApp's own database.
///
/// Everything above the `WhatsAppStore` protocol is driven by a fake in the tests; this
/// file is driven by a fixture database the suite builds in a temporary directory, with
/// invented chats and invented messages. Neither ever opens the owner's store.
///
/// A connection is created per call and closed when the call returns. It costs a file
/// open on a read-only handle — nothing measurable — and buys the absence of shared
/// mutable state, which is what makes `Sendable` here an honest claim rather than an
/// `@unchecked` assertion.
public struct SystemWhatsAppStore: WhatsAppStore {
    private let path: String

    public init(path: String = Configuration.defaultDatabasePath) {
        self.path = path
    }

    /// The tables without which this server cannot answer anything. Checked before any
    /// query runs, because a WhatsApp update that renames one of these should say so rather
    /// than surface as a SQL syntax error nobody can act on.
    static let requiredTables = [
        "ZWACHATSESSION", "ZWAMESSAGE", "ZWAMEDIAITEM", "ZWAGROUPMEMBER",
        "ZWAPROFILEPUSHNAME",
    ]

    /// Tables that add a field when present and cost nothing when absent. A WhatsApp
    /// version without one of these should lose that one field, not every read — so each is
    /// checked at runtime and its columns are replaced by `NULL` literals when it is gone.
    /// `whatsapp_status` names any that are missing, so an absent table reads as a feature
    /// that is off rather than as data that does not exist.
    static let optionalTables = ["ZWAMESSAGEDATAITEM", "ZWAPROFILEPICTUREITEM", "ZWAGROUPINFO"]

    // MARK: Availability

    public func availability() -> StoreAvailability {
        guard FileManager.default.fileExists(atPath: path) else {
            return .databaseMissing(path: path)
        }
        do {
            let database = try ReadOnlyDatabase(path: path)
            let present = try database.tableNames()
            let missing = Self.requiredTables.filter { !present.contains($0) }
            return missing.isEmpty ? .ready : .schemaUnexpected(missingTables: missing)
        } catch {
            return .databaseUnreadable(path: path, detail: Self.describe(error))
        }
    }

    public func databaseInfo() -> DatabaseInfo {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let exists = attributes != nil

        // A `-wal` with bytes in it means WhatsApp has written messages the main file
        // does not carry yet. `immutable=1` never reads it, so those messages are simply
        // not visible until WhatsApp checkpoints. Reported, never worked around: reading
        // the WAL means taking locks on a database another app is actively using.
        let walSize =
            (try? FileManager.default.attributesOfItem(atPath: path + "-wal"))?[.size] as? Int64
        var missing: [String] = []
        var absentOptional: [String] = []
        var chatCount: Int?
        var messageCount: Int?

        if exists, let database = try? ReadOnlyDatabase(path: path) {
            let present = (try? database.tableNames()) ?? []
            missing = Self.requiredTables.filter { !present.contains($0) }
            absentOptional = Self.optionalTables.filter { !present.contains($0) }
            if missing.isEmpty {
                chatCount = try? Self.count(database, "SELECT COUNT(*) FROM ZWACHATSESSION")
                messageCount = try? Self.count(database, "SELECT COUNT(*) FROM ZWAMESSAGE")
            }
        }

        return DatabaseInfo(
            path: path,
            exists: exists,
            size: attributes?[.size] as? Int64,
            modified: attributes?[.modificationDate] as? Date,
            hasPendingWAL: (walSize ?? 0) > 0,
            missingTables: missing,
            absentOptionalTables: absentOptional,
            chatCount: chatCount,
            messageCount: messageCount)
    }

    // MARK: Chats

    public func chats(matching query: ChatQuery) async throws -> [Chat] {
        let database = try open()
        let hidden = try Self.hiddenColumn(database)
        var clauses: [String] = []
        var bindings: [SQLiteBinding] = []

        if !query.includeArchived { clauses.append("s.ZARCHIVED = 0") }
        if !query.includeHidden, hidden != nil { clauses.append("s.ZHIDDEN = 0") }
        if let name = query.name {
            clauses.append("wa_contains(COALESCE(s.ZPARTNERNAME, s.ZCONTACTJID), ?)")
            bindings.append(.text(name))
        }
        if !query.kinds.isEmpty {
            let codes = query.kinds.map { String($0.sessionTypeCode) }.joined(separator: ", ")
            clauses.append("s.ZSESSIONTYPE IN (\(codes))")
        }

        let sql = """
            \(Self.chatColumns(hidden: hidden))
            \(Self.chatSource)
            \(Self.whereClause(clauses))
            ORDER BY s.ZLASTMESSAGEDATE DESC, s.Z_PK DESC
            LIMIT ? OFFSET ?
            """
        bindings.append(.int(Int64(query.limit)))
        bindings.append(.int(Int64(query.offset)))

        var chats: [Chat] = []
        try database.query(sql, bindings) { row in chats.append(Self.chat(from: row)) }
        return chats
    }

    public func chat(id: Int64) async throws -> Chat? {
        let database = try open()
        let sql = """
            \(Self.chatColumns(hidden: try Self.hiddenColumn(database)))
            \(Self.chatSource)
            WHERE s.Z_PK = ?
            """
        var found: Chat?
        try database.query(sql, [.int(id)]) { row in found = Self.chat(from: row) }
        return found
    }

    /// `s.ZHIDDEN` when this WhatsApp version has it, nil when it does not — in which case
    /// the column is replaced by a literal and the flag comes back nil rather than false, so
    /// "this server cannot tell" never reads as "this chat is not hidden".
    private static func hiddenColumn(_ database: ReadOnlyDatabase) throws -> String? {
        let columns = (try? database.columnNames(of: "ZWACHATSESSION")) ?? []
        return columns.contains("ZHIDDEN") ? "s.ZHIDDEN" : nil
    }

    private static func chatColumns(hidden: String?) -> String {
        """
        SELECT s.Z_PK, s.ZCONTACTJID, s.ZPARTNERNAME, s.ZSESSIONTYPE, s.ZARCHIVED,
               s.ZUNREADCOUNT, s.ZLASTMESSAGEDATE, s.ZLASTMESSAGETEXT,
               (SELECT COUNT(*) FROM ZWAMESSAGE m WHERE m.ZCHATSESSION = s.Z_PK),
               COALESCE(lm.ZMESSAGEDATE, lm.ZSENTDATE),
               \(hidden ?? "NULL")
        """
    }

    private static let chatSource = """
        FROM ZWACHATSESSION s
        LEFT JOIN ZWAMESSAGE lm ON lm.Z_PK = s.ZLASTMESSAGE
        """

    /// How far ahead of now a session date has to be before it is read as a pin marker
    /// rather than a date. WhatsApp inflates a pinned chat's sort key by whole millennia —
    /// five thousand years is the smallest offset observed — so a year leaves an enormous
    /// margin against a machine whose clock is merely wrong.
    private static let pinHorizon: TimeInterval = 365 * 24 * 60 * 60

    private static func chat(from row: ReadOnlyDatabase.Row) -> Chat {
        let jid = row.text(1) ?? ""
        // ZLASTMESSAGEDATE is a sort key first and a date second: WhatsApp adds millennia
        // to it to hold a pinned chat at the top of its own ORDER BY. Reporting it as the
        // moment the last message arrived is how a chat comes back dated the year 9026.
        let sortDate = row.date(6)
        let isPinned = sortDate.map { $0.timeIntervalSinceNow > pinHorizon } ?? false
        return Chat(
            id: row.int(0),
            jid: jid,
            // A chat with no stored name is normal — an unsaved number shows as its JID
            // in WhatsApp too, so showing it here matches what the person sees.
            name: row.text(2) ?? jid,
            kind: ChatKind(sessionTypeCode: Int(row.int(3))),
            isArchived: row.bool(4),
            isHidden: row.isNull(10) ? nil : row.bool(10),
            unreadCount: Int(row.int(5)),
            messageCount: Int(row.int(8)),
            // The message the session points at carries the honest date. Fall back to the
            // session's own only when it is not inflated; a pinned chat whose last message
            // has been deleted has no date to report, and says so by omission.
            lastMessageDate: row.date(9) ?? (isPinned ? nil : sortDate),
            lastMessageText: row.text(7),
            isPinned: isPinned)
    }

    // MARK: Messages

    public func messages(matching query: MessageQuery) async throws -> MessagePage {
        try await page(matching: query, requiringMediaRow: false)
    }

    /// The same rows, narrowed to those that carry a `ZWAMEDIAITEM`. `media_list` differs
    /// from `chat_get` in what it selects, never in how it describes what it found.
    public func media(matching query: MessageQuery) async throws -> MessagePage {
        try await page(matching: query, requiringMediaRow: true)
    }

    public func message(id: Int64) async throws -> Message? {
        let database = try open()
        let shape = try Self.messageShape(database)
        let profileNames = try Self.profileNames(database)
        let picturePaths = try profilePicturePaths(database)

        let sql = """
            \(shape.columns)
            \(shape.source)
            WHERE m.Z_PK = ?
            """
        var found: Message?
        try database.query(sql, [.int(id)]) { row in
            found = self.message(
                from: row, profileNames: profileNames, picturePaths: picturePaths)
        }
        return found
    }

    private func page(matching query: MessageQuery, requiringMediaRow: Bool) async throws
        -> MessagePage
    {
        let database = try open()
        let shape = try Self.messageShape(database)
        var filter = Self.messageFilter(query)
        if requiringMediaRow { filter.clauses.append("m.ZMEDIAITEM IS NOT NULL") }

        // Counted over the same source, so "142 matching" and the rows below it can never
        // disagree — the joins that add a link preview or a media row must not change the
        // arithmetic.
        let total = try Self.count(
            database,
            """
            SELECT COUNT(*)
            \(shape.source)
            \(Self.whereClause(filter.clauses))
            """,
            filter.bindings)

        let sql = """
            \(shape.columns)
            \(shape.source)
            \(Self.whereClause(filter.clauses))
            ORDER BY \(Self.messageDate) \(query.newestFirst ? "DESC" : "ASC"),
                     m.Z_PK \(query.newestFirst ? "DESC" : "ASC")
            LIMIT ? OFFSET ?
            """
        var bindings = filter.bindings
        bindings.append(.int(Int64(query.limit)))
        bindings.append(.int(Int64(query.offset)))

        // Both loaded once per call rather than joined per row: 446 and 386 rows on the
        // measured library, and a mention's JID cannot be joined against at all — it is
        // embedded in ZTEXT, not in any column.
        let profileNames = try Self.profileNames(database)
        let picturePaths = try profilePicturePaths(database)

        var rows: [Message] = []
        try database.query(sql, bindings) { row in
            rows.append(
                self.message(from: row, profileNames: profileNames, picturePaths: picturePaths))
        }
        return MessagePage(rows: rows, total: total)
    }

    /// The column list and the FROM/JOIN block, built together so their indices cannot
    /// drift apart.
    ///
    /// A missing optional table is handled by selecting `NULL` in place of its columns
    /// instead of by dropping them, which keeps every index below fixed. The alternative —
    /// a shorter column list — makes each reader's index depend on what the schema happened
    /// to have, which is the kind of thing that fails silently.
    private static func messageShape(_ database: ReadOnlyDatabase) throws
        -> (columns: String, source: String)
    {
        let present = try database.tableNames()
        let hasPreviews = present.contains("ZWAMESSAGEDATAITEM")

        let columns = """
            -- ZPUSHNAME is deliberately not selected. It once held the name a sender chose
            -- for themselves; this schema stores WhatsApp's own binary payload there, and
            -- most rows are base64 rather than text. Reading it yields a display name like
            -- "CNXy9s8GIAA=". ZWAPROFILEPUSHNAME is the name source instead.
            SELECT m.Z_PK, m.ZCHATSESSION, COALESCE(s.ZPARTNERNAME, s.ZCONTACTJID),
                   \(messageDate), m.ZSENTDATE, m.ZISFROMME,
                   COALESCE(NULLIF(gm.ZCONTACTNAME, ''), NULLIF(pn.ZPUSHNAME, '')),
                   gm.ZMEMBERJID, m.ZFROMJID, m.ZTEXT, m.ZMESSAGETYPE, m.ZSTARRED,
                   m.ZGROUPEVENTTYPE, m.ZMESSAGESTATUS, m.ZMESSAGEERRORSTATUS,
                   mi.ZMEDIALOCALPATH, mi.ZFILESIZE, mi.ZMOVIEDURATION, mi.ZTITLE,
                   mi.ZLATITUDE, mi.ZLONGITUDE, mi.ZVCARDNAME, mi.ZVCARDSTRING,
                   mi.ZMEDIAORIGIN, mi.ZMEDIAURL, mi.ZAUTHORNAME,
                   \(hasPreviews ? "di.ZCONTENT1, di.ZTITLE, di.ZSUMMARY" : "NULL, NULL, NULL")
            """

        // ZWAMESSAGEDATAITEM holds up to 12 rows for one message, one per link in it.
        // Joined on the message alone, a message with several links comes back a dozen
        // times and every count above it is wrong. ZINDEX = 0 is exactly one row per
        // message on all 703 the measured library covers.
        let previewJoin =
            hasPreviews
            ? "LEFT JOIN ZWAMESSAGEDATAITEM di ON di.ZMESSAGE = m.Z_PK AND di.ZINDEX = 0" : ""

        let source = """
            FROM ZWAMESSAGE m
            JOIN ZWACHATSESSION s ON s.Z_PK = m.ZCHATSESSION
            LEFT JOIN ZWAGROUPMEMBER gm ON gm.Z_PK = m.ZGROUPMEMBER
            LEFT JOIN ZWAPROFILEPUSHNAME pn ON pn.ZJID = gm.ZMEMBERJID
            LEFT JOIN ZWAMEDIAITEM mi ON mi.Z_PK = m.ZMEDIAITEM
            \(previewJoin)
            """

        return (columns, source)
    }

    private func message(
        from row: ReadOnlyDatabase.Row, profileNames: [String: String],
        picturePaths: [String: String]
    ) -> Message {
        let typeCode = Int(row.int(10))
        let rawText = row.text(9)

        var text: String?
        var mentions: [Mention] = []
        // A group event's ZTEXT is the subject's JID, and a deleted message's is either
        // empty or a JID too. Neither is anything a reader should see as a message body.
        if !MessageTypeCode.groupEventCodes.contains(typeCode),
            typeCode != MessageTypeCode.deletedForEveryone,
            let rawText
        {
            let resolved = JIDDisplay.mentions(in: rawText, profileNames: profileNames)
            text = resolved.text
            mentions = resolved.mentions
        }

        let memberJID = row.text(7)
        let fromJID = row.text(8)
        var sender: Identity?
        if let jid = memberJID ?? fromJID {
            // Three sources, in falling order of trust. ZWAGROUPMEMBER.ZCONTACTNAME is the
            // documented one but is an empty string on every row of this schema, which is
            // why it is emptied to NULL rather than tested for nil; ZWAPROFILEPUSHNAME
            // carries the name for most group senders. A one-to-one message has no member
            // row at all — there the sender IS the chat — so the absence of that row is
            // what makes the chat's own name the right answer.
            let name =
                row.text(6)
                ?? (memberJID == nil
                    ? (row.text(2) ?? jid) : JIDDisplay.render(jid, profileNames: profileNames))
            sender = Identity(
                jid: jid, displayName: name, profilePicturePath: picturePaths[jid])
        }

        return Message(
            id: row.int(0),
            chatID: row.int(1),
            chatName: row.text(2) ?? "",
            date: row.date(3) ?? Date(timeIntervalSinceReferenceDate: 0),
            sentDate: row.date(4),
            isFromMe: row.bool(5),
            sender: sender,
            isStarred: row.bool(11),
            delivery: DeliveryState(
                rawCode: Int(row.int(13)), errorCode: row.optionalInt(14).map(Int.init)),
            body: body(
                from: row, typeCode: typeCode, rawText: rawText, profileNames: profileNames,
                picturePaths: picturePaths),
            text: text,
            mentions: mentions)
    }

    /// Decides what a message *is*, once, against the type gates each case documents.
    ///
    /// Order matters and is not arbitrary. An attachment is settled before a link preview
    /// because WhatsApp attaches a preview row to photos too, and a photo with a link in its
    /// caption is a photo. A location and a contact card come first because their columns
    /// are the ones that mean something else entirely on any other type.
    private func body(
        from row: ReadOnlyDatabase.Row, typeCode: Int, rawText: String?,
        profileNames: [String: String], picturePaths: [String: String]
    ) -> MessageBody {
        if typeCode == MessageTypeCode.deletedForEveryone { return .deletedForEveryone }

        if MessageTypeCode.groupEventCodes.contains(typeCode) {
            let actor = JIDDisplay.identity(
                row.text(8) ?? "", profileNames: profileNames, picturePaths: picturePaths)
            let subject = rawText.flatMap { candidate -> Identity? in
                guard candidate.contains("@") else { return nil }
                return JIDDisplay.identity(
                    candidate, profileNames: profileNames, picturePaths: picturePaths)
            }
            return .groupEvent(
                GroupEvent(
                    code: row.optionalInt(12).map(Int.init), actor: actor, subject: subject))
        }

        if let coordinates = Coordinates(
            latitude: row.optionalDouble(19), longitude: row.optionalDouble(20),
            typeCode: typeCode)
        {
            return .location(coordinates)
        }

        if let card = ContactCard(
            name: row.text(21), vcard: row.text(22), typeCode: typeCode)
        {
            return .contactCard(card)
        }

        let mediaOrigin = row.optionalInt(23).map(Int.init)
        if let kind = AttachmentKind(typeCode: typeCode, mediaOrigin: mediaOrigin) {
            let remote = row.text(24)
            return .attachment(
                Attachment(
                    kind: kind,
                    localPath: resolvedMediaPath(row.text(15)),
                    fileSize: row.optionalInt(16),
                    // Gated on the kind, not merely on being non-zero: on a document this
                    // column counts something else entirely — see AttachmentKind.hasDuration.
                    // Zero elsewhere is "not a timed medium", not "a zero-second clip".
                    duration: kind.hasDuration
                        ? row.optionalInt(17).flatMap { $0 > 0 ? Int($0) : nil } : nil,
                    title: row.text(18),
                    author: row.text(25),
                    // Two of the 5359 populated rows hold something that is not a link.
                    remoteURL: remote?.hasPrefix("http") == true ? remote : nil))
        }

        let preview = LinkPreview(url: row.text(26), title: row.text(27), summary: row.text(28))
        if !preview.isEmpty || typeCode == MessageTypeCode.link { return .link(preview) }

        if typeCode == MessageTypeCode.text { return .text }
        return .other(typeCode: typeCode)
    }

    /// `ZJID → ZPUSHNAME`, the only working name source for a group sender or a mention's
    /// LID.
    private static func profileNames(_ database: ReadOnlyDatabase) throws -> [String: String] {
        var names: [String: String] = [:]
        try database.query("SELECT ZJID, ZPUSHNAME FROM ZWAPROFILEPUSHNAME") { row in
            if let jid = row.text(0), let name = row.text(1), !name.isEmpty {
                names[jid] = name
            }
        }
        return names
    }

    /// `ZJID → absolute path`, for the parties whose profile picture is on this Mac.
    ///
    /// **`ZWAPROFILEPICTUREITEM.ZPATH` is not always a path.** 250 of the 386 rows in the
    /// measured library hold a real `Media/…` path; **109 hold a 64-to-128-character blob**
    /// with no path shape at all, and 27 are null. Handed over unchecked, a third of these
    /// would be reported as files that do not exist. Two gates: the `Media/` prefix, then
    /// the same on-disk check every other path in this server passes.
    private func profilePicturePaths(_ database: ReadOnlyDatabase) throws -> [String: String] {
        guard try database.tableNames().contains("ZWAPROFILEPICTUREITEM") else { return [:] }
        var paths: [String: String] = [:]
        try database.query("SELECT ZJID, ZPATH FROM ZWAPROFILEPICTUREITEM") { row in
            guard let jid = row.text(0), let stored = row.text(1),
                stored.hasPrefix("Media/"), let resolved = resolvedMediaPath(stored)
            else { return }
            paths[jid] = resolved
        }
        return paths
    }

    /// WhatsApp stores a media path relative to `Message/` inside its own container, so the
    /// stored `Media/…/file.jpg` resolves against nothing on its own. Derived from the
    /// database's own location rather than hard-coded, so a fixture database in a temporary
    /// directory resolves against that directory instead of the real container.
    private var mediaRoot: URL {
        URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .appendingPathComponent("Message")
    }

    /// An absolute path, and only when the file is genuinely on disk.
    ///
    /// The contract these tools state is that a path present means the file is on this Mac.
    /// WhatsApp keeps the media row long after it has evicted the file itself — most rows
    /// have no path at all — so the row's existence does not settle it and the check is
    /// what keeps the promise true.
    private func resolvedMediaPath(_ storedPath: String?) -> String? {
        guard let storedPath, !storedPath.isEmpty else { return nil }
        let absolute = mediaRoot.appendingPathComponent(storedPath).path
        return FileManager.default.fileExists(atPath: absolute) ? absolute : nil
    }

    // MARK: Groups

    /// `ZWAGROUPINFO` columns this store knows how to read, when present. Not part of
    /// `requiredTables`: `group_get` is the only tool that needs this table, so a WhatsApp
    /// version that drops or renames it should take down that one tool, not every read this
    /// server does.
    private static let groupInfoColumns = [
        "ZCREATIONDATE", "ZCREATORJID", "ZSUBJECTTIMESTAMP", "ZSUBJECTOWNERJID", "ZPICTUREID",
    ]
    /// `ZFIRSTNAME` is missing from this list on purpose — see `GroupMember`.
    private static let groupMemberColumns = ["ZMEMBERJID", "ZCONTACTNAME", "ZISADMIN", "ZISACTIVE"]

    public func group(chatID: Int64) async throws -> Group? {
        let database = try open()
        guard try database.tableNames().contains("ZWAGROUPINFO") else {
            throw ToolError.storeUnavailable(.schemaUnexpected(missingTables: ["ZWAGROUPINFO"]))
        }
        let profileNames = try Self.profileNames(database)
        let picturePaths = try profilePicturePaths(database)

        // Built from whichever of the expected columns this file's ZWAGROUPINFO actually
        // has, rather than assuming all five exist: a column WhatsApp has renamed or
        // dropped should make that one field come back nil, not fail the whole read.
        let infoColumns = (try? database.columnNames(of: "ZWAGROUPINFO")) ?? []
        let presentInfo = Self.groupInfoColumns.filter { infoColumns.contains($0) }

        var creationDate: Date?
        var creatorJID: String?
        var subjectDate: Date?
        var subjectOwnerJID: String?
        var pictureID: String?
        var hasInfoRow = false

        if !presentInfo.isEmpty {
            let sql =
                "SELECT \(presentInfo.joined(separator: ", ")) FROM ZWAGROUPINFO WHERE ZCHATSESSION = ?"
            try database.query(sql, [.int(chatID)]) { row in
                hasInfoRow = true
                for (offset, column) in presentInfo.enumerated() {
                    let index = Int32(offset)
                    switch column {
                    case "ZCREATIONDATE": creationDate = row.date(index)
                    case "ZCREATORJID": creatorJID = row.text(index)
                    case "ZSUBJECTTIMESTAMP": subjectDate = row.date(index)
                    case "ZSUBJECTOWNERJID": subjectOwnerJID = row.text(index)
                    case "ZPICTUREID": pictureID = row.text(index)
                    default: break
                    }
                }
            }
        }
        // No row for this chat in a table that otherwise exists: `Dispatch` has already
        // confirmed the chat is a group, so this is unexpected rather than the normal
        // "not a group" case.
        guard hasInfoRow else { return nil }

        // The group's own icon is filed under the group's JID, exactly like a person's.
        var groupJID: String?
        try database.query(
            "SELECT ZCONTACTJID FROM ZWACHATSESSION WHERE Z_PK = ?", [.int(chatID)]
        ) { row in groupJID = row.text(0) }

        let memberColumns = (try? database.columnNames(of: "ZWAGROUPMEMBER")) ?? []
        let presentMembers = Self.groupMemberColumns.filter { memberColumns.contains($0) }
        var members: [GroupMember] = []
        if presentMembers.contains("ZMEMBERJID") {
            let sql =
                "SELECT \(presentMembers.joined(separator: ", ")) FROM ZWAGROUPMEMBER WHERE ZCHATSESSION = ?"
            try database.query(sql, [.int(chatID)]) { row in
                var jid: String?
                // ZCONTACTNAME is an empty string on every row of the measured library,
                // never NULL, so emptiness has to be checked explicitly rather than trusted
                // as absence.
                var contactName: String?
                var isAdmin: Bool?
                var isActive: Bool?
                for (offset, column) in presentMembers.enumerated() {
                    let index = Int32(offset)
                    switch column {
                    case "ZMEMBERJID": jid = row.text(index)
                    case "ZCONTACTNAME": contactName = row.text(index)
                    case "ZISADMIN": isAdmin = row.isNull(index) ? nil : row.bool(index)
                    case "ZISACTIVE": isActive = row.isNull(index) ? nil : row.bool(index)
                    default: break
                    }
                }
                guard let jid else { return }
                let name =
                    (contactName?.isEmpty == false ? contactName : nil)
                    ?? JIDDisplay.render(jid, profileNames: profileNames)
                members.append(
                    GroupMember(
                        identity: Identity(
                            jid: jid, displayName: name, profilePicturePath: picturePaths[jid]),
                        isAdmin: isAdmin, isActive: isActive))
            }
        }

        return Group(
            creationDate: creationDate,
            creator: creatorJID.map {
                JIDDisplay.identity($0, profileNames: profileNames, picturePaths: picturePaths)
            },
            subjectChangedDate: subjectDate,
            subjectChangedBy: subjectOwnerJID.map {
                JIDDisplay.identity($0, profileNames: profileNames, picturePaths: picturePaths)
            },
            pictureID: pictureID,
            picturePath: groupJID.flatMap { picturePaths[$0] },
            members: members)
    }

    // MARK: Query building

    /// `ZMESSAGEDATE` is the message's own timestamp and is what WhatsApp orders by. It is
    /// non-null on all 27138 rows of the measured library, so the fallback below is
    /// defensive rather than load-bearing: it costs nothing, and a null slipping through
    /// would otherwise sort a message to one end of the conversation instead of its place
    /// in it.
    private static let messageDate = "COALESCE(m.ZMESSAGEDATE, m.ZSENTDATE, 0)"

    private static func messageFilter(_ query: MessageQuery)
        -> (clauses: [String], bindings: [SQLiteBinding])
    {
        var clauses: [String] = []
        var bindings: [SQLiteBinding] = []

        if let chatID = query.chatID {
            clauses.append("m.ZCHATSESSION = ?")
            bindings.append(.int(chatID))
        }
        if let text = query.text {
            clauses.append("wa_contains(m.ZTEXT, ?)")
            bindings.append(.text(text))
        }
        if let after = query.after {
            clauses.append("\(messageDate) >= ?")
            bindings.append(.double(after.timeIntervalSinceReferenceDate))
        }
        if let before = query.before {
            clauses.append("\(messageDate) < ?")
            bindings.append(.double(before.timeIntervalSinceReferenceDate))
        }
        if let fromMe = query.fromMe {
            clauses.append("m.ZISFROMME = ?")
            bindings.append(.int(fromMe ? 1 : 0))
        }
        if !query.kinds.isEmpty {
            // Interpolated rather than bound because these are predicates this code
            // produced from a closed enumeration; no caller string reaches the SQL.
            let predicates = query.kinds.map(\.sqlPredicate).joined(separator: " OR ")
            clauses.append("(\(predicates))")
        }
        if query.starredOnly { clauses.append("m.ZSTARRED = 1") }

        return (clauses, bindings)
    }

    private static func whereClause(_ clauses: [String]) -> String {
        clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: "\n  AND ")
    }

    // MARK: Plumbing

    private func open() throws -> ReadOnlyDatabase {
        do {
            return try ReadOnlyDatabase(path: path)
        } catch {
            guard FileManager.default.fileExists(atPath: path) else {
                throw ToolError.storeUnavailable(.databaseMissing(path: path))
            }
            throw ToolError.storeUnavailable(
                .databaseUnreadable(path: path, detail: Self.describe(error)))
        }
    }

    private static func count(
        _ database: ReadOnlyDatabase, _ sql: String, _ bindings: [SQLiteBinding] = []
    ) throws -> Int {
        var total = 0
        try database.query(sql, bindings) { row in total = Int(row.int(0)) }
        return total
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case let failure as ReadOnlyDatabase.OpenFailure: return failure.detail
        case let failure as ReadOnlyDatabase.QueryFailure: return failure.detail
        default: return error.localizedDescription
        }
    }
}

extension ChatKind {
    /// The `ZSESSIONTYPE` value this kind is stored as. `.unknown` has no code of its
    /// own — it is what an unrecognised one becomes — so it maps to a value nothing
    /// matches, keeping a filter on it empty rather than accidentally broad.
    var sessionTypeCode: Int {
        switch self {
        case .individual: return 0
        case .group: return 1
        case .broadcast: return 2
        case .status: return 3
        case .unknown: return -1
        }
    }
}

extension MediaKind {
    /// How this kind is recognised in SQL.
    ///
    /// Seven of the nine are a `ZMESSAGETYPE` and nothing else. The two audio kinds share
    /// type 3 and are told apart by `ZMEDIAORIGIN` alone — which is why this is a predicate
    /// rather than a list of type codes, and why the media row has to be in the FROM block
    /// for a kind filter to work at all.
    var sqlPredicate: String {
        switch self {
        case .photo: return "m.ZMESSAGETYPE = \(MessageTypeCode.image)"
        case .video: return "m.ZMESSAGETYPE = \(MessageTypeCode.video)"
        case .gif: return "m.ZMESSAGETYPE = \(MessageTypeCode.gif)"
        case .sticker: return "m.ZMESSAGETYPE = \(MessageTypeCode.sticker)"
        case .document: return "m.ZMESSAGETYPE = \(MessageTypeCode.document)"
        case .location: return "m.ZMESSAGETYPE = \(MessageTypeCode.location)"
        case .contactCard: return "m.ZMESSAGETYPE = \(MessageTypeCode.contact)"
        case .voiceNote:
            return "(m.ZMESSAGETYPE = \(MessageTypeCode.audio) AND mi.ZMEDIAORIGIN = 1)"
        case .audioFile:
            return
                "(m.ZMESSAGETYPE = \(MessageTypeCode.audio) AND (mi.ZMEDIAORIGIN IS NULL OR mi.ZMEDIAORIGIN <> 1))"
        }
    }
}
