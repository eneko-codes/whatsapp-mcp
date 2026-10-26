import Foundation

// Readers for what lives outside ChatStorage: calls, live-location sessions, labels, the
// address book, the LID↔phone tables and channels.
//
// Every table and column named here was read from the `.schema` of a copy of WhatsApp's
// own databases, not assumed. A table or column that is missing is reported as a changed
// schema and never as an empty result, because "WhatsApp reorganised its storage" and
// "you have no calls" must not look the same.

// MARK: - Models

public struct CallEvent: Sendable, Equatable {
    public var id: Int64
    public var date: Date?
    public var durationSeconds: Double?
    /// The number WhatsApp stored. Which value means answered, declined or failed has not
    /// been established, so it is reported as a code, the way delivery codes are.
    public var outcomeCode: Int64?
    public var incoming: Bool?
    public var missed: Bool?
    public var missedReasonCode: Int64?
    public var video: Bool?
    public var groupJID: String?
    public var creatorJID: String?
    public var participants: [CallParticipant]
}

public struct CallParticipant: Sendable, Equatable {
    public var jid: String
    public var outcomeCode: Int64?
}

public struct CallQuery: Sendable, Equatable {
    public var after: Date?
    public var before: Date?
    public var newestFirst = true
    public var limit = 50
    public var offset = 0
    public init() {}
}

public struct LocationSharing: Sendable, Equatable {
    public struct Outgoing: Sendable, Equatable {
        public var chat: String?
        public var participant: String?
        public var started: Date?
        public var ends: Date?
        public var sequence: Int64?
    }
    public struct Recipient: Sendable, Equatable {
        public var chat: String?
        public var jid: String?
        public var expires: Date?
    }
    public var outgoing: [Outgoing]
    public var recipients: [Recipient]
}

public struct Label: Sendable, Equatable {
    public var id: Int64
    public var name: String?
    public var colorID: Int64?
    public var active: Bool?
    public var predefinedID: Int64?
    public var order: Int64?
    public var labeledCount: Int
}

public struct LabeledEntity: Sendable, Equatable {
    public var entityType: Int64?
    public var contactJID: String?
    public var entityKey: String?
    public var date: Date?
}

public struct AddressBookEntry: Sendable, Equatable {
    public var id: Int64
    public var fullName: String?
    public var givenName: String?
    public var lastName: String?
    public var businessName: String?
    public var phoneNumber: String?
    public var lid: String?
    public var whatsappID: String?
    public var username: String?
    public var about: String?
    public var lastUpdated: Date?
}

public struct AddressBookQuery: Sendable, Equatable {
    public var name: String?
    public var limit = 50
    public var offset = 0
    public init() {}
}

public struct LIDMatch: Sendable, Equatable {
    public var lid: String?
    public var phoneNumber: String?
    public var displayName: String?
    public var username: String?
    public var pushName: String?
    /// Which table the row came from, so a caller can tell a pairing WhatsApp recorded from
    /// a name it merely showed.
    public var source: String
}

public struct Channel: Sendable, Equatable {
    public var jid: String
    public var name: String?
    public var addedByLID: String?
    public var addedByName: String?
}

/// One seam for everything outside the chat store.
public protocol DomainReader: Sendable {
    func calls(matching query: CallQuery) throws -> (calls: [CallEvent], source: SourceInfo)
    func locationSharing(limit: Int) throws -> (sharing: LocationSharing, source: SourceInfo)
    func labels() throws -> (labels: [Label], source: SourceInfo)
    func labeledEntities(labelID: Int64, limit: Int) throws
        -> (label: Label?, entities: [LabeledEntity], source: SourceInfo)
    func addressBook(matching query: AddressBookQuery) throws
        -> (entries: [AddressBookEntry], source: SourceInfo)
    func lidLookup(_ value: String) throws
        -> (matches: [LIDMatch], sources: [SourceInfo], notes: [String])
    func channels(name: String?, limit: Int) throws -> (channels: [Channel], source: SourceInfo)
}

// MARK: - Implementation over the live databases

public struct LiveDomainReader: DomainReader {
    private let databases: ContainerDatabases

    public init(databases: ContainerDatabases) {
        self.databases = databases
    }

    /// Opens one database live and checks that the tables and columns this reader
    /// uses are there, naming whatever is not.
    private func open(_ database: AllowedDatabase, requires needs: [String: [String]]) throws
        -> (ReadOnlyDatabase, SourceInfo)
    {
        let (connection, info) = try databases.open(database)
        var missing: [String] = []
        for (table, columns) in needs.sorted(by: { $0.key < $1.key }) {
            let present = try connection.columnNames(of: table)
            if present.isEmpty {
                missing.append(table)
            } else {
                missing += columns.filter { !present.contains($0) }.map { "\(table).\($0)" }
            }
        }
        guard missing.isEmpty else {
            throw ToolError.storeFailure(
                "\(database.rawValue) does not have \(missing.joined(separator: ", ")). WhatsApp's "
                    + "layout is undocumented and this version of it differs from the one this "
                    + "server was written against; use db_schema to see what is there.")
        }
        return (connection, info)
    }

    // MARK: Calls

    public func calls(matching query: CallQuery) throws -> (calls: [CallEvent], source: SourceInfo) {
        let (database, info) = try open(
            .callHistory,
            requires: [
                "ZWACDCALLEVENT": [
                    "Z_PK", "ZDATE", "ZDURATION", "ZOUTCOME", "ZGROUPJIDSTRING",
                    "ZGROUPCALLCREATORUSERJIDSTRING", "Z1CALLEVENTS",
                ],
                "ZWAAGGREGATECALLEVENT": [
                    "Z_PK", "ZINCOMING", "ZMISSED", "ZMISSEDREASON", "ZVIDEO",
                ],
                "ZWACDCALLEVENTPARTICIPANT": ["Z_PK", "ZJIDSTRING", "ZOUTCOME", "Z1PARTICIPANTS"],
            ])
        var calls: [CallEvent] = []
        var aggregateIDs: [Int64?] = []
        let direction = query.newestFirst ? "DESC" : "ASC"
        try database.query(
            """
            SELECT c.Z_PK, c.ZDATE, c.ZDURATION, c.ZOUTCOME, c.ZGROUPJIDSTRING,
                   c.ZGROUPCALLCREATORUSERJIDSTRING, a.ZINCOMING, a.ZMISSED, a.ZMISSEDREASON,
                   a.ZVIDEO, c.Z1CALLEVENTS
            FROM ZWACDCALLEVENT c
            LEFT JOIN ZWAAGGREGATECALLEVENT a ON a.Z_PK = c.Z1CALLEVENTS
            WHERE (?1 IS NULL OR c.ZDATE >= ?1) AND (?2 IS NULL OR c.ZDATE < ?2)
            ORDER BY c.ZDATE \(direction), c.Z_PK \(direction)
            LIMIT ?3 OFFSET ?4
            """,
            [
                Self.bind(query.after), Self.bind(query.before), .int(Int64(query.limit)),
                .int(Int64(query.offset)),
            ]
        ) { row in
            calls.append(
                CallEvent(
                    id: row.int(0), date: row.date(1), durationSeconds: row.optionalDouble(2),
                    outcomeCode: row.optionalInt(3), incoming: row.isNull(6) ? nil : row.bool(6),
                    missed: row.isNull(7) ? nil : row.bool(7), missedReasonCode: row.optionalInt(8),
                    video: row.isNull(9) ? nil : row.bool(9),
                    groupJID: Self.nonEmpty(row.text(4)), creatorJID: Self.nonEmpty(row.text(5)),
                    participants: []))
            aggregateIDs.append(row.optionalInt(10))
        }
        // Core Data names a foreign key Z<entity number><relationship>. Both Z1CALLEVENTS
        // and Z1PARTICIPANTS carry entity 1, the aggregate, so participants hang off the
        // aggregate that groups the call events and not off one event. Inferred from the
        // column names; the entity numbering itself is in Z_PRIMARYKEY and was not read.
        for index in calls.indices {
            guard let aggregateID = aggregateIDs[index] else { continue }
            try database.query(
                "SELECT ZJIDSTRING, ZOUTCOME FROM ZWACDCALLEVENTPARTICIPANT WHERE Z1PARTICIPANTS = ? ORDER BY Z_PK",
                [.int(aggregateID)]
            ) { row in
                if let jid = Self.nonEmpty(row.text(0)) {
                    calls[index].participants.append(
                        CallParticipant(jid: jid, outcomeCode: row.optionalInt(1)))
                }
            }
        }
        return (calls, info)
    }

    // MARK: Live location

    public func locationSharing(limit: Int) throws -> (sharing: LocationSharing, source: SourceInfo) {
        let (database, info) = try open(
            .location,
            requires: [
                "ZWALOCATIONSENDER": [
                    "ZCHAT", "ZPARTICIPANT", "ZTIMESTAMP", "ZENDDATE", "ZSEQUENCENUMBER",
                ],
                "ZWAFINALLOCATIONRECIPIENT": ["ZCHATJID", "ZJID", "ZEXPIRATION"],
            ])
        var sharing = LocationSharing(outgoing: [], recipients: [])
        // ZLOCATIONMESSAGE, a protobuf blob of coordinates, is deliberately not read: it is
        // not decoded here, and a blob in the answer would be a number of bytes.
        try database.query(
            """
            SELECT ZCHAT, ZPARTICIPANT, ZTIMESTAMP, ZENDDATE, ZSEQUENCENUMBER
            FROM ZWALOCATIONSENDER ORDER BY ZTIMESTAMP DESC LIMIT ?
            """, [.int(Int64(limit))]
        ) { row in
            sharing.outgoing.append(
                .init(
                    chat: Self.nonEmpty(row.text(0)), participant: Self.nonEmpty(row.text(1)),
                    started: row.date(2), ends: row.date(3), sequence: row.optionalInt(4)))
        }
        try database.query(
            "SELECT ZCHATJID, ZJID, ZEXPIRATION FROM ZWAFINALLOCATIONRECIPIENT ORDER BY ZEXPIRATION DESC LIMIT ?",
            [.int(Int64(limit))]
        ) { row in
            sharing.recipients.append(
                .init(
                    chat: Self.nonEmpty(row.text(0)), jid: Self.nonEmpty(row.text(1)),
                    expires: row.date(2)))
        }
        return (sharing, info)
    }

    // MARK: Labels

    private static let labelTables: [String: [String]] = [
        "ZWASMBLABEL": [
            "Z_PK", "ZLABELID", "ZNAME", "ZCOLORID", "ZISACTIVE", "ZPREDEFINEDID", "ZORDERINDEX",
        ],
        "Z_1PROXIES": ["Z_1LABELS", "Z_2PROXIES"],
        "ZWASMBLABELEDENTITYPROXY": ["Z_PK", "ZENTITYTYPE", "ZCONTACTJID", "ZENTITYKEY", "ZDATE"],
    ]

    public func labels() throws -> (labels: [Label], source: SourceInfo) {
        let (database, info) = try open(.labels, requires: Self.labelTables)
        return (try labelRows(database), info)
    }

    private func labelRows(_ database: ReadOnlyDatabase) throws -> [Label] {
        var labels: [Label] = []
        try database.query(
            """
            SELECT l.ZLABELID, l.ZNAME, l.ZCOLORID, l.ZISACTIVE, l.ZPREDEFINEDID, l.ZORDERINDEX,
                   (SELECT count(*) FROM Z_1PROXIES p WHERE p.Z_1LABELS = l.Z_PK)
            FROM ZWASMBLABEL l ORDER BY l.ZORDERINDEX, l.ZLABELID
            """
        ) { row in
            labels.append(
                Label(
                    id: row.int(0), name: Self.nonEmpty(row.text(1)), colorID: row.optionalInt(2),
                    active: row.isNull(3) ? nil : row.bool(3), predefinedID: row.optionalInt(4),
                    order: row.optionalInt(5), labeledCount: Int(row.int(6))))
        }
        return labels
    }

    public func labeledEntities(labelID: Int64, limit: Int) throws
        -> (label: Label?, entities: [LabeledEntity], source: SourceInfo)
    {
        let (database, info) = try open(.labels, requires: Self.labelTables)
        var entities: [LabeledEntity] = []
        try database.query(
            """
            SELECT e.ZENTITYTYPE, e.ZCONTACTJID, e.ZENTITYKEY, e.ZDATE
            FROM ZWASMBLABEL l
            JOIN Z_1PROXIES p ON p.Z_1LABELS = l.Z_PK
            JOIN ZWASMBLABELEDENTITYPROXY e ON e.Z_PK = p.Z_2PROXIES
            WHERE l.ZLABELID = ? ORDER BY e.ZDATE DESC LIMIT ?
            """, [.int(labelID), .int(Int64(limit))]
        ) { row in
            entities.append(
                LabeledEntity(
                    entityType: row.optionalInt(0), contactJID: Self.nonEmpty(row.text(1)),
                    entityKey: Self.nonEmpty(row.text(2)), date: row.date(3)))
        }
        let label = try labelRows(database).first { $0.id == labelID }
        return (label, entities, info)
    }

    // MARK: Address book

    public func addressBook(matching query: AddressBookQuery) throws
        -> (entries: [AddressBookEntry], source: SourceInfo)
    {
        let (database, info) = try open(
            .contacts,
            requires: [
                "ZWAADDRESSBOOKCONTACT": [
                    "Z_PK", "ZFULLNAME", "ZGIVENNAME", "ZLASTNAME", "ZBUSINESSNAME",
                    "ZPHONENUMBER", "ZLID", "ZWHATSAPPID", "ZUSERNAME", "ZABOUTTEXT",
                    "ZLASTUPDATED",
                ]
            ])
        var entries: [AddressBookEntry] = []
        try database.query(
            """
            SELECT Z_PK, ZFULLNAME, ZGIVENNAME, ZLASTNAME, ZBUSINESSNAME, ZPHONENUMBER, ZLID,
                   ZWHATSAPPID, ZUSERNAME, ZABOUTTEXT, ZLASTUPDATED
            FROM ZWAADDRESSBOOKCONTACT
            WHERE ?1 IS NULL OR wa_contains(coalesce(ZFULLNAME, '') || ' ' || coalesce(ZGIVENNAME, '')
                || ' ' || coalesce(ZLASTNAME, '') || ' ' || coalesce(ZBUSINESSNAME, '')
                || ' ' || coalesce(ZPHONENUMBER, ''), ?1)
            ORDER BY coalesce(ZFULLNAME, ZBUSINESSNAME, ''), Z_PK LIMIT ?2 OFFSET ?3
            """,
            [query.name.map { .text($0) } ?? .null, .int(Int64(query.limit)), .int(Int64(query.offset))]
        ) { row in
            entries.append(
                AddressBookEntry(
                    id: row.int(0), fullName: Self.nonEmpty(row.text(1)),
                    givenName: Self.nonEmpty(row.text(2)), lastName: Self.nonEmpty(row.text(3)),
                    businessName: Self.nonEmpty(row.text(4)), phoneNumber: Self.nonEmpty(row.text(5)),
                    lid: Self.nonEmpty(row.text(6)), whatsappID: Self.nonEmpty(row.text(7)),
                    username: Self.nonEmpty(row.text(8)), about: Self.nonEmpty(row.text(9)),
                    lastUpdated: row.date(10)))
        }
        return (entries, info)
    }

    // MARK: LID

    /// A LID or a phone number, with or without its `@…` suffix. Matches the stored value
    /// exactly or up to the `@`, because which form each table keeps is not established.
    public func lidLookup(_ value: String) throws
        -> (matches: [LIDMatch], sources: [SourceInfo], notes: [String])
    {
        let bare = value.split(separator: "@", maxSplits: 1).first.map(String.init) ?? value
        guard !bare.isEmpty else {
            throw ToolError.badArgument(name: "value", reason: "give a LID or a phone number")
        }
        var matches: [LIDMatch] = []
        var sources: [SourceInfo] = []
        var notes: [String] = []

        let (lidDatabase, lidInfo) = try open(
            .lid,
            requires: [
                "ZWAPHONENUMBERLIDPAIR": ["ZLID", "ZPHONENUMBER"],
                "ZWALIDPROPERTIES": ["ZLID", "ZDISPLAYNAME", "ZUSERNAME"],
            ])
        sources.append(lidInfo)
        try lidDatabase.query(
            """
            SELECT ZLID, ZPHONENUMBER FROM ZWAPHONENUMBERLIDPAIR
            WHERE ZLID = ?1 OR substr(ZLID, 1, length(?1) + 1) = ?1 || '@'
               OR ZPHONENUMBER = ?1 OR substr(ZPHONENUMBER, 1, length(?1) + 1) = ?1 || '@' LIMIT 20
            """, [.text(bare)]
        ) { row in
            matches.append(
                LIDMatch(
                    lid: Self.nonEmpty(row.text(0)), phoneNumber: Self.nonEmpty(row.text(1)),
                    displayName: nil, username: nil, pushName: nil,
                    source: "LID.ZWAPHONENUMBERLIDPAIR"))
        }
        try lidDatabase.query(
            """
            SELECT ZLID, ZDISPLAYNAME, ZUSERNAME FROM ZWALIDPROPERTIES
            WHERE ZLID = ?1 OR substr(ZLID, 1, length(?1) + 1) = ?1 || '@' LIMIT 20
            """, [.text(bare)]
        ) { row in
            matches.append(
                LIDMatch(
                    lid: Self.nonEmpty(row.text(0)), phoneNumber: nil,
                    displayName: Self.nonEmpty(row.text(1)), username: Self.nonEmpty(row.text(2)),
                    pushName: nil, source: "LID.ZWALIDPROPERTIES"))
        }

        // The extended-chat store keeps its own LID↔phone pairing beside a push name. This
        // lookup is still useful without it, so a failure here is reported in `notes`
        // rather than failing the call — but it is reported, never swallowed.
        do {
            let (extended, extendedInfo) = try open(
                .extendedChat,
                requires: [
                    "contact_metadata": [
                        "contact_lid", "contact_pn", "contact_username", "contact_push_name",
                    ]
                ])
            sources.append(extendedInfo)
            try extended.query(
                """
                SELECT contact_lid, contact_pn, contact_username, contact_push_name
                FROM contact_metadata
                WHERE contact_lid = ?1 OR substr(contact_lid, 1, length(?1) + 1) = ?1 || '@'
                   OR contact_pn = ?1 OR substr(contact_pn, 1, length(?1) + 1) = ?1 || '@' LIMIT 20
                """, [.text(bare)]
            ) { row in
                matches.append(
                    LIDMatch(
                        lid: Self.nonEmpty(row.text(0)), phoneNumber: Self.nonEmpty(row.text(1)),
                        displayName: nil, username: Self.nonEmpty(row.text(2)),
                        pushName: Self.nonEmpty(row.text(3)),
                        source: "ExtChatDB.contact_metadata"))
            }
        } catch let failure as SourceError {
            notes.append("ExtChatDB.contact_metadata was not searched: \(failure.message)")
        } catch let failure as ToolError {
            notes.append("ExtChatDB.contact_metadata was not searched: \(failure.message)")
        }
        return (matches, sources, notes)
    }

    // MARK: Channels

    public func channels(name: String?, limit: Int) throws
        -> (channels: [Channel], source: SourceInfo)
    {
        let (database, info) = try open(
            .extendedChat,
            requires: [
                "channel_metadata": [
                    "channel_metadata_id", "channel_jid", "channel_name", "added_by_lid",
                    "added_by_push_name",
                ]
            ])
        var channels: [Channel] = []
        try database.query(
            """
            SELECT channel_jid, channel_name, added_by_lid, added_by_push_name
            FROM channel_metadata WHERE ?1 IS NULL OR wa_contains(channel_name, ?1)
            ORDER BY channel_name, channel_metadata_id LIMIT ?2
            """, [name.map { .text($0) } ?? .null, .int(Int64(limit))]
        ) { row in
            channels.append(
                Channel(
                    jid: row.text(0) ?? "", name: Self.nonEmpty(row.text(1)),
                    addedByLID: Self.nonEmpty(row.text(2)),
                    addedByName: Self.nonEmpty(row.text(3))))
        }
        return (channels, info)
    }

    // MARK: Helpers

    private static func bind(_ date: Date?) -> SQLiteBinding {
        date.map { .double($0.timeIntervalSinceReferenceDate) } ?? .null
    }

    /// Core Data stores an absent string as NULL or as an empty one, depending on the
    /// writer; neither is a value.
    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        // Names, usernames and "about" lines are written by other people.
        return text.displaySafe
    }
}
