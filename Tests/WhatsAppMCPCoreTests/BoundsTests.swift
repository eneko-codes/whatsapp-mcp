import AVFoundation
import Foundation
import Testing

@testable import WhatsAppMCPCore

/// The edges of the tool standard for this server's own tools: each bound and one past it,
/// the text of each notice, pages and windows that chain, the longest result, and the texts
/// the model reads. Every chat, message, number and table in here is invented; the chat
/// store is the in-memory fake and the other databases are built in a temporary directory.
@Suite("Bounds")
struct BoundsTests {

    private static func padded(_ index: Int) -> String {
        String(format: "%04d", index)
    }

    /// `text` grown with filler to exactly `width` characters.
    private static func filled(_ text: String, to width: Int) -> String {
        text + String(repeating: "x", count: max(0, width - text.count))
    }

    private static let base = Fixtures.date(2026, 8, 9, 12, 0)

    // MARK: Listings

    /// One listing tool, and data that gives it `count` rows of the widest ordinary width,
    /// in the order the tool lists them. `row` is text found in row `index` only.
    struct Listing: Sendable, CustomTestStringConvertible {
        var tool: String
        var things: String
        var limits: ClosedRange<Int>
        var defaultLimit: Int
        var call: @Sendable (Int, [String: Value]) async -> (text: String, isError: Bool)
        var row: @Sendable (Int) -> String

        var testDescription: String { tool }

        func call(_ count: Int, _ extra: [String: Value] = [:]) async -> (text: String, isError: Bool) {
            await call(count, extra)
        }

        func rows(in text: String, of count: Int) -> [Int] {
            (0..<count).filter { text.contains(row($0)) }
        }
    }

    /// Runs a tool against the in-memory chat store.
    private static func onStore(
        _ tool: String, _ arguments: [String: Value], _ extra: [String: Value],
        _ fill: (FakeWhatsAppStore) -> Void
    ) async -> (text: String, isError: Bool) {
        let store = FakeWhatsAppStore()
        fill(store)
        return await WhatsAppMCPCoreTests.call(
            WhatsAppTools(store: store, calendar: Fixtures.calendar), tool,
            arguments.merging(extra) { _, new in new })
    }

    /// Runs a tool against databases built from `statements` in a fresh fake container.
    private static func onDatabases(
        _ tool: String, _ arguments: [String: Value], _ extra: [String: Value],
        _ databases: [(AllowedDatabase, [String])]
    ) async -> (text: String, isError: Bool) {
        guard let fake = try? FakeContainer() else { return ("no container", true) }
        defer { fake.remove() }
        for (database, statements) in databases {
            do { try fake.build(database, statements) } catch { return ("\(error)", true) }
        }
        return await WhatsAppMCPCoreTests.call(
            fake.tools(), tool, arguments.merging(extra) { _, new in new })
    }

    private static func reference(minutesBefore minutes: Int) -> Double {
        base.addingTimeInterval(TimeInterval(-60 * minutes)).timeIntervalSinceReferenceDate
    }

    /// A message whose text is exactly as wide as a row shows, so the row is the widest an
    /// ordinary message row gets without being clipped.
    private static func message(
        _ index: Int, chat: Int64 = 1, body: MessageBody = .text, width: Int = Configuration.textWidth
    ) -> Message {
        Fixtures.message(
            id: Int64(1_000 + index), chatID: chat, chatName: "Invented Neighbourhood Group",
            text: filled("Message \(padded(index)) ", to: width),
            at: base.addingTimeInterval(TimeInterval(-60 * index)), body: body)
    }

    static let chats = Listing(
        tool: ToolCatalog.chatsName, things: "chats", limits: Configuration.limitRange,
        defaultLimit: Configuration.defaultLimit,
        call: { count, extra in
            await onStore(ToolCatalog.chatsName, [:], extra) { store in
                store.chatsValue = (0..<count).map {
                    Fixtures.chat(
                        id: Int64($0 + 1), name: "Chat \(padded($0)) of the invented association",
                        kind: .group, unread: 12)
                }
            }
        },
        row: { "  Chat \(padded($0)) of" })

    static let chatGet = Listing(
        tool: ToolCatalog.chatGetName, things: "messages", limits: Configuration.messageLimitRange,
        defaultLimit: Configuration.defaultMessageLimit,
        call: { count, extra in
            await onStore(ToolCatalog.chatGetName, ["chat_id": 1], extra) { store in
                store.chatsValue = [Fixtures.chat(id: 1, name: "Invented Neighbourhood Group", kind: .group)]
                store.messagesValue = (0..<count).map { message($0) }
            }
        },
        row: { "Message \(padded($0)) " })

    static let search = Listing(
        tool: ToolCatalog.searchName, things: "messages", limits: Configuration.messageLimitRange,
        defaultLimit: Configuration.defaultMessageLimit,
        call: { count, extra in
            await onStore(ToolCatalog.searchName, ["query": "Message"], extra) { store in
                store.messagesValue = (0..<count).map { message($0, chat: Int64($0 % 3 + 1)) }
            }
        },
        row: { "Message \(padded($0)) " })

    static let media = Listing(
        tool: ToolCatalog.mediaName, things: "messages", limits: Configuration.messageLimitRange,
        defaultLimit: Configuration.defaultMessageLimit,
        call: { count, extra in
            await onStore(ToolCatalog.mediaName, [:], extra) { store in
                store.messagesValue = (0..<count).map {
                    // A caption is the exception on a photo, and a short one when there is one.
                    message(
                        $0,
                        body: Fixtures.attachment(
                            .photo,
                            path: "/Users/user/Library/Group Containers/group.example/Message/Media/"
                                + "invented@s.whatsapp.net/a/b/\(UUID().uuidString).jpg"),
                        width: 40)
                }
            }
        },
        row: { "Message \(padded($0)) " })

    static let members = Listing(
        tool: ToolCatalog.groupGetName, things: "members", limits: Configuration.limitRange,
        defaultLimit: Configuration.defaultLimit,
        call: { count, extra in
            await onStore(ToolCatalog.groupGetName, ["chat_id": 2], extra) { store in
                store.chatsValue = [Fixtures.chat(id: 2, name: "Invented Group", kind: .group)]
                store.groupValue[2] = Group(
                    creationDate: base, creator: nil, subjectChangedDate: nil, subjectChangedBy: nil,
                    pictureID: nil,
                    // Reversed, so the listing has to sort them itself.
                    members: (0..<count).reversed().map {
                        GroupMember(
                            identity: Identity(
                                jid: "3460\(padded($0))000@s.whatsapp.net",
                                displayName: "Invented Member Name \(padded($0))"),
                            isAdmin: false, isActive: false)
                    })
            }
        },
        row: { "3460\(padded($0))000@s.whatsapp.net" })

    private static let callTables = [
        "CREATE TABLE ZWAAGGREGATECALLEVENT (Z_PK INTEGER PRIMARY KEY, ZINCOMING INTEGER, ZMISSED INTEGER, ZMISSEDREASON INTEGER, ZVIDEO INTEGER, ZFIRSTDATE TIMESTAMP)",
        "CREATE TABLE ZWACDCALLEVENT (Z_PK INTEGER PRIMARY KEY, ZOUTCOME INTEGER, Z1CALLEVENTS INTEGER, ZDATE TIMESTAMP, ZDURATION FLOAT, ZGROUPJIDSTRING VARCHAR, ZGROUPCALLCREATORUSERJIDSTRING VARCHAR)",
        "CREATE TABLE ZWACDCALLEVENTPARTICIPANT (Z_PK INTEGER PRIMARY KEY, ZOUTCOME INTEGER, Z1PARTICIPANTS INTEGER, ZJIDSTRING VARCHAR)",
    ]

    static let calls = Listing(
        tool: ToolCatalog.callsName, things: "calls", limits: Configuration.limitRange,
        defaultLimit: Configuration.defaultLimit,
        call: { count, extra in
            let rows = (0..<count).flatMap { index in
                [
                    "INSERT INTO ZWAAGGREGATECALLEVENT VALUES (\(index + 1), 1, 0, NULL, 1, 0)",
                    "INSERT INTO ZWACDCALLEVENT VALUES (\(index + 1), 2, \(index + 1), \(reference(minutesBefore: index)), 83.4, NULL, NULL)",
                    "INSERT INTO ZWACDCALLEVENTPARTICIPANT VALUES (\(index + 1), 2, \(index + 1), '3460\(padded(index))111@s.whatsapp.net')",
                ]
            }
            return await onDatabases(ToolCatalog.callsName, [:], extra, [(.callHistory, callTables + rows)])
        },
        row: { "3460\(padded($0))111@s.whatsapp.net" })

    static let location = Listing(
        tool: ToolCatalog.locationSharingName, things: "sharing rows", limits: Configuration.limitRange,
        defaultLimit: Configuration.defaultLimit,
        call: { count, extra in
            let statements =
                [
                    "CREATE TABLE ZWALOCATIONSENDER (Z_PK INTEGER PRIMARY KEY, ZSEQUENCENUMBER INTEGER, ZENDDATE TIMESTAMP, ZTIMESTAMP TIMESTAMP, ZCHAT VARCHAR, ZPARTICIPANT VARCHAR, ZLOCATIONMESSAGE BLOB)",
                    "CREATE TABLE ZWAFINALLOCATIONRECIPIENT (Z_PK INTEGER PRIMARY KEY, ZEXPIRATION TIMESTAMP, ZCHATJID VARCHAR, ZJID VARCHAR, ZMESSAGEID VARCHAR)",
                ]
                + (0..<count).map {
                    "INSERT INTO ZWALOCATIONSENDER VALUES (\($0 + 1), 1, \(reference(minutesBefore: $0 - 60)), \(reference(minutesBefore: $0)), '3461\(padded($0))000@s.whatsapp.net', NULL, NULL)"
                }
            return await onDatabases(ToolCatalog.locationSharingName, [:], extra, [(.location, statements)])
        },
        row: { "3461\(padded($0))000@s.whatsapp.net" })

    static let labels = Listing(
        tool: ToolCatalog.labelsName, things: "labels", limits: Configuration.limitRange,
        defaultLimit: Configuration.defaultLimit,
        call: { count, extra in
            let statements =
                [
                    "CREATE TABLE ZWASMBLABEL (Z_PK INTEGER PRIMARY KEY, ZLABELID INTEGER, ZNAME VARCHAR, ZCOLORID INTEGER, ZISACTIVE INTEGER, ZPREDEFINEDID INTEGER, ZORDERINDEX INTEGER)",
                    "CREATE TABLE Z_1PROXIES (Z_1LABELS INTEGER, Z_2PROXIES INTEGER)",
                    "CREATE TABLE ZWASMBLABELEDENTITYPROXY (Z_PK INTEGER PRIMARY KEY, ZENTITYTYPE INTEGER, ZDATE TIMESTAMP, ZCONTACTJID VARCHAR, ZENTITYKEY VARCHAR)",
                ]
                + (0..<count).map {
                    "INSERT INTO ZWASMBLABEL VALUES (\($0 + 1), \($0 + 100), 'Invented label \(padded($0))', 3, 1, 0, \($0))"
                }
            return await onDatabases(ToolCatalog.labelsName, [:], extra, [(.labels, statements)])
        },
        row: { "Invented label \(padded($0))" })

    static let addressBook = Listing(
        tool: ToolCatalog.addressBookName, things: "entries", limits: Configuration.limitRange,
        defaultLimit: Configuration.defaultLimit,
        call: { count, extra in
            let statements =
                [
                    "CREATE TABLE ZWAADDRESSBOOKCONTACT (Z_PK INTEGER PRIMARY KEY, ZFULLNAME VARCHAR, ZGIVENNAME VARCHAR, ZLASTNAME VARCHAR, ZBUSINESSNAME VARCHAR, ZPHONENUMBER VARCHAR, ZLID VARCHAR, ZWHATSAPPID VARCHAR, ZUSERNAME VARCHAR, ZABOUTTEXT VARCHAR, ZLASTUPDATED TIMESTAMP)"
                ]
                + (0..<count).map {
                    "INSERT INTO ZWAADDRESSBOOKCONTACT VALUES (\($0 + 1), 'Person \(padded($0)) Invented', 'Person', 'Invented', NULL, '+3460\(padded($0))00', '9000\(padded($0))@lid', '3460\(padded($0))00@s.whatsapp.net', NULL, 'Available', NULL)"
                }
            return await onDatabases(ToolCatalog.addressBookName, [:], extra, [(.contacts, statements)])
        },
        row: { "Person \(padded($0)) Invented" })

    static let lid = Listing(
        tool: ToolCatalog.lidLookupName, things: "records", limits: Configuration.limitRange,
        defaultLimit: Configuration.defaultLimit,
        call: { count, extra in
            let statements =
                [
                    "CREATE TABLE ZWAPHONENUMBERLIDPAIR (Z_PK INTEGER PRIMARY KEY, ZTIMESTAMP TIMESTAMP, ZLID VARCHAR, ZPHONENUMBER VARCHAR)",
                    "CREATE TABLE ZWALIDPROPERTIES (Z_PK INTEGER PRIMARY KEY, ZDISPLAYNAME VARCHAR, ZLID VARCHAR, ZUSERNAME VARCHAR)",
                ]
                + (0..<count).map {
                    "INSERT INTO ZWAPHONENUMBERLIDPAIR VALUES (\($0 + 1), 0, '111222@lid', '3460\(padded($0))99@s.whatsapp.net')"
                }
            return await onDatabases(
                ToolCatalog.lidLookupName, ["value": "111222@lid"], extra, [(.lid, statements)])
        },
        row: { "3460\(padded($0))99@s.whatsapp.net" })

    static let channels = Listing(
        tool: ToolCatalog.channelsName, things: "channels", limits: Configuration.limitRange,
        defaultLimit: Configuration.defaultLimit,
        call: { count, extra in
            let statements =
                [
                    "CREATE TABLE channel_metadata (channel_metadata_id INTEGER PRIMARY KEY, channel_jid TEXT NOT NULL, channel_name TEXT, added_by_lid TEXT, added_by_push_name TEXT)"
                ]
                + (0..<count).map {
                    "INSERT INTO channel_metadata VALUES (\($0 + 1), '120363\(padded($0))@newsletter', 'Invented channel \(padded($0))', NULL, 'Invented Adder')"
                }
            return await onDatabases(ToolCatalog.channelsName, [:], extra, [(.extendedChat, statements)])
        },
        row: { "Invented channel \(padded($0))" })

    static let tables = Listing(
        tool: ToolCatalog.dbTablesName, things: "tables and views", limits: Configuration.tableLimitRange,
        defaultLimit: Configuration.defaultTableLimit,
        call: { count, extra in
            let statements = (0..<count).map {
                "CREATE TABLE ZINVENTEDTABLENAME\(padded($0)) (Z_PK INTEGER PRIMARY KEY)"
            }
            return await onDatabases(ToolCatalog.dbTablesName, ["db": "Sticker"], extra, [(.sticker, statements)])
        },
        row: { "ZINVENTEDTABLENAME\(padded($0))  [" })

    /// A statement about as wide as one of WhatsApp's ordinary tables: a dozen columns.
    static let schema = Listing(
        tool: ToolCatalog.dbSchemaName, things: "statements", limits: Configuration.schemaLimitRange,
        defaultLimit: Configuration.defaultSchemaLimit,
        call: { count, extra in
            let columns = (0..<14).map { "ZINVENTEDCOLUMN\($0) VARCHAR" }.joined(separator: ", ")
            let statements = (0..<count).map {
                "CREATE TABLE ZTABLE\(padded($0)) (Z_PK INTEGER PRIMARY KEY, \(columns))"
            }
            return await onDatabases(ToolCatalog.dbSchemaName, ["db": "Sticker"], extra, [(.sticker, statements)])
        },
        row: { "ZTABLE\(padded($0)) (" })

    static let listings = [
        chats, chatGet, search, media, members, calls, location, labels, addressBook, lid,
        channels, tables, schema,
    ]

    // MARK: Pages

    @Test("A call with no optional argument returns one default page, announced before the data", arguments: listings)
    func defaultPage(_ listing: Listing) async {
        let total = listing.defaultLimit + 5
        let result = await listing.call(total)
        #expect(!result.isError, Comment(rawValue: result.text))
        #expect(
            result.text.hasPrefix(
                "Showing 1–\(listing.defaultLimit) of \(total) \(listing.things). Pass offset=\(listing.defaultLimit) for the next page.\n"),
            Comment(rawValue: String(result.text.prefix(300))))
        #expect(listing.rows(in: result.text, of: total) == Array(0..<listing.defaultLimit))
        #expect(result.text.utf16.count <= ToolStandard.usualPage, "\(result.text.utf16.count)")
    }

    @Test("A result that holds every row from the start carries no notice", arguments: listings)
    func wholeListingHasNoNotice(_ listing: Listing) async {
        let result = await listing.call(7)
        #expect(listing.rows(in: result.text, of: 7) == Array(0..<7))
        #expect(!result.text.contains("Showing"))
        #expect(!result.text.contains("is outside"))
        #expect(!result.text.contains("is clipped"))
    }

    @Test("limit at its maximum is used as asked, and a full page of the widest rows fits a result", arguments: listings)
    func limitAtItsMaximum(_ listing: Listing) async {
        let maximum = listing.limits.upperBound
        let total = maximum + 10
        let result = await listing.call(total, ["limit": .int(maximum)])
        #expect(!result.text.contains("is outside"))
        #expect(
            result.text.hasPrefix(
                "Showing 1–\(maximum) of \(total) \(listing.things). Pass offset=\(maximum) for the next page.\n"),
            Comment(rawValue: String(result.text.prefix(300))))
        #expect(listing.rows(in: result.text, of: total) == Array(0..<maximum))
        #expect(result.text.utf16.count <= ToolStandard.longestResult)
    }

    @Test("limit one past either end is moved to the nearest value, and the result says which", arguments: listings)
    func limitPastItsRange(_ listing: Listing) async {
        let maximum = listing.limits.upperBound
        let total = maximum + 10

        let over = await listing.call(total, ["limit": .int(maximum + 1)])
        #expect(
            over.text.hasPrefix(
                """
                limit=\(maximum + 1) is outside 1–\(maximum); \(maximum) was used.
                Showing 1–\(maximum) of \(total) \(listing.things). Pass offset=\(maximum) for the next page.

                """), Comment(rawValue: String(over.text.prefix(300))))
        #expect(listing.rows(in: over.text, of: total) == Array(0..<maximum))

        let under = await listing.call(total, ["limit": .int(0)])
        #expect(under.text.hasPrefix("limit=0 is outside 1–\(maximum); 1 was used.\nShowing 1–1 of \(total) "))
        #expect(listing.rows(in: under.text, of: total) == [0])
    }

    @Test("Each page starts where the last one ended, and the last says that is all", arguments: listings)
    func pagesChain(_ listing: Listing) async {
        let first = await listing.call(7, ["limit": .int(3)])
        #expect(first.text.hasPrefix("Showing 1–3 of 7 \(listing.things). Pass offset=3 for the next page.\n"))
        #expect(listing.rows(in: first.text, of: 7) == [0, 1, 2])

        let second = await listing.call(7, ["limit": .int(3), "offset": .int(3)])
        #expect(second.text.hasPrefix("Showing 4–6 of 7 \(listing.things). Pass offset=6 for the next page.\n"))
        #expect(listing.rows(in: second.text, of: 7) == [3, 4, 5])

        let last = await listing.call(7, ["limit": .int(3), "offset": .int(6)])
        #expect(last.text.hasPrefix("Showing 7–7 of 7 \(listing.things). That is all.\n"))
        #expect(listing.rows(in: last.text, of: 7) == [6])
    }

    @Test("An offset past the end returns no row and says so; a negative one is moved to zero", arguments: listings)
    func offsetEdges(_ listing: Listing) async {
        let past = await listing.call(7, ["offset": .int(7)])
        #expect(!past.isError)
        #expect(past.text.hasPrefix("Showing 0 of 7 \(listing.things): offset=7 is past the end. That is all.\n"))
        #expect(listing.rows(in: past.text, of: 7).isEmpty)

        let negative = await listing.call(7, ["offset": .int(-1)])
        let range = Configuration.offsetRange
        #expect(negative.text.hasPrefix("offset=-1 is outside \(range.lowerBound)–\(range.upperBound); 0 was used.\n\n"))
        #expect(listing.rows(in: negative.text, of: 7) == Array(0..<7))

        let far = await listing.call(7, ["offset": .int(range.upperBound + 1)])
        #expect(far.text.hasPrefix("offset=\(range.upperBound + 1) is outside \(range.lowerBound)–\(range.upperBound); \(range.upperBound) was used.\n"))
    }

    @Test("A wrong type is refused with the form expected", arguments: listings)
    func wrongTypeIsRefused(_ listing: Listing) async {
        let result = await listing.call(3, ["limit": "10"])
        #expect(result.isError)
        #expect(result.text == "Argument 'limit' is not valid: a whole number was expected")
    }

    @Test("Live-location pages run through the sessions and on into the recipients")
    func locationPagesCrossTables() async {
        let statements =
            [
                "CREATE TABLE ZWALOCATIONSENDER (Z_PK INTEGER PRIMARY KEY, ZSEQUENCENUMBER INTEGER, ZENDDATE TIMESTAMP, ZTIMESTAMP TIMESTAMP, ZCHAT VARCHAR, ZPARTICIPANT VARCHAR, ZLOCATIONMESSAGE BLOB)",
                "CREATE TABLE ZWAFINALLOCATIONRECIPIENT (Z_PK INTEGER PRIMARY KEY, ZEXPIRATION TIMESTAMP, ZCHATJID VARCHAR, ZJID VARCHAR, ZMESSAGEID VARCHAR)",
            ]
            + (0..<3).map {
                "INSERT INTO ZWALOCATIONSENDER VALUES (\($0 + 1), 1, 0, \(Self.reference(minutesBefore: $0)), 'session-\($0)@s.whatsapp.net', NULL, NULL)"
            }
            + (0..<2).map {
                "INSERT INTO ZWAFINALLOCATIONRECIPIENT VALUES (\($0 + 1), \(Self.reference(minutesBefore: $0)), 'chat@g.us', 'recipient-\($0)@s.whatsapp.net', 'M\($0)')"
            }
        func page(_ offset: Int) async -> String {
            await Self.onDatabases(
                ToolCatalog.locationSharingName, ["limit": 2, "offset": .int(offset)], [:],
                [(.location, statements)]
            ).text
        }
        func shown(_ text: String) -> [String] {
            ["session-0", "session-1", "session-2", "recipient-0", "recipient-1"].filter { text.contains($0 + "@") }
        }
        let first = await page(0)
        #expect(first.hasPrefix("Showing 1–2 of 5 sharing rows. Pass offset=2 for the next page.\n"))
        #expect(shown(first) == ["session-0", "session-1"])
        let second = await page(2)
        #expect(second.hasPrefix("Showing 3–4 of 5 sharing rows. Pass offset=4 for the next page.\n"))
        #expect(shown(second) == ["session-2", "recipient-0"])
        let third = await page(4)
        #expect(third.hasPrefix("Showing 5–5 of 5 sharing rows. That is all.\n"))
        #expect(shown(third) == ["recipient-1"])
    }

    // MARK: Rows wider than any maximum foresaw

    @Test("A page of rows too wide to fit holds fewer of them and says where to resume")
    func widePageShrinks() async throws {
        // A chat name is never clipped, so a search across chats with very long names is the
        // widest a message row can get.
        let wide = String(repeating: "w", count: 1_000)
        let messages = (0..<100).map { (index: Int) -> Message in
            let name = "Room-" + Self.padded(index) + "-" + wide
            let date = Self.base.addingTimeInterval(TimeInterval(-60 * index))
            return Fixtures.message(
                id: Int64(1_000 + index), chatID: Int64(index + 1), chatName: name, text: "invented",
                at: date)
        }
        var offset = 0
        var seen: [Int] = []
        while offset < messages.count {
            let result = await Self.onStore(
                ToolCatalog.searchName, ["query": "invented", "limit": 100, "offset": .int(offset)], [:]
            ) { $0.messagesValue = messages }
            #expect(result.text.utf16.count <= ToolStandard.longestResult)
            let shown = (0..<messages.count).filter { result.text.contains("  Room-\(Self.padded($0))-w") }
            let last = try #require(shown.last)
            #expect(shown.first == offset)
            #expect(shown.count < 100)
            let next = last + 1 < messages.count ? "Pass offset=\(last + 1) for the next page." : "That is all."
            #expect(result.text.hasPrefix("Showing \(offset + 1)–\(last + 1) of 100 messages. \(next)\n"))
            seen += shown
            offset = last + 1
        }
        #expect(seen == Array(0..<messages.count))
    }

    // MARK: Clipped fields

    @Test("A row's long text is clipped, and the page says so only when it was")
    func clippedTextIsAnnounced() async {
        let long = "Start of a long invented message " + String(repeating: "y", count: 2_000)
        let clipped = await Self.onStore(ToolCatalog.chatGetName, ["chat_id": 1], [:]) { store in
            store.chatsValue = [Fixtures.chat(id: 1, name: "Ane")]
            store.messagesValue = [Fixtures.message(id: 10, chatID: 1, chatName: "Ane", text: long)]
        }
        #expect(
            clipped.text.hasPrefix(
                "Text is clipped to \(Configuration.textWidth) characters in each row. Read one in full with message_get.\n\n"))
        #expect(clipped.text.contains(String(long.prefix(Configuration.textWidth - 1)) + "…"))
        #expect(!clipped.text.contains(String(long.prefix(Configuration.textWidth))))

        let exact = await Self.onStore(ToolCatalog.chatGetName, ["chat_id": 1], [:]) { store in
            store.chatsValue = [Fixtures.chat(id: 1, name: "Ane")]
            store.messagesValue = [
                Fixtures.message(id: 10, chatID: 1, chatName: "Ane", text: Self.filled("a", to: Configuration.textWidth))
            ]
        }
        #expect(!exact.text.contains("is clipped"))
    }

    @Test("A call's participants are clipped, and the notice names where the rest is")
    func clippedParticipantsAreAnnounced() async {
        let rows =
            ["INSERT INTO ZWAAGGREGATECALLEVENT VALUES (1, 1, 0, NULL, 1, 0)",
             "INSERT INTO ZWACDCALLEVENT VALUES (1, 2, 1, \(Self.reference(minutesBefore: 0)), 83.4, '1203@g.us', NULL)"]
            + (0..<40).map {
                "INSERT INTO ZWACDCALLEVENTPARTICIPANT VALUES (\($0 + 1), 2, 1, '3460\(Self.padded($0))111@s.whatsapp.net')"
            }
        let result = await Self.onDatabases(ToolCatalog.callsName, [:], [:], [(.callHistory, Self.callTables + rows)])
        #expect(
            result.text.hasPrefix(
                "Participants is clipped to \(Configuration.participantsWidth) characters in each row. Read one in full with db_query (CallHistory, ZWACDCALLEVENTPARTICIPANT).\n\n"),
            Comment(rawValue: result.text))
    }

    // MARK: Held back

    @Test("Archived and hidden chats left out are counted, with the argument that brings them in")
    func heldBackChatsAreAnnounced() async {
        let result = await Self.onStore(ToolCatalog.chatsName, [:], [:]) { store in
            store.chatsValue = [
                Fixtures.chat(id: 1, name: "Ane"), Fixtures.chat(id: 2, name: "Old", archived: true),
                Fixtures.chat(id: 3, name: "Older", archived: true), Fixtures.chat(id: 4, name: "Quiet", hidden: true),
            ]
        }
        #expect(
            result.text.hasPrefix(
                """
                2 archived chats are not shown. Pass include_archived=true to include them.
                1 hidden chats are not shown. Pass include_hidden=true to include them.

                1 chat
                """), Comment(rawValue: result.text))

        let all = await Self.onStore(
            ToolCatalog.chatsName, ["include_archived": true, "include_hidden": true], [:]
        ) { store in
            store.chatsValue = [
                Fixtures.chat(id: 1, name: "Ane"), Fixtures.chat(id: 2, name: "Old", archived: true),
            ]
        }
        #expect(!all.text.contains("not shown"))
    }

    // MARK: Identifiers

    @Test("An id outside its range, or sent as text, is refused and never moved")
    func identifiersAreRefused() async {
        let top = Configuration.identifierRange.upperBound
        for value: Value in [0, -1, .int(top + 1), "1", 1.5] {
            let result = await Self.onStore(ToolCatalog.chatGetName, ["chat_id": value], [:]) {
                $0.chatsValue = [Fixtures.chat(id: 1, name: "Ane")]
            }
            #expect(result.isError, "\(value)")
            #expect(
                result.text == "Argument 'chat_id' is not valid: an id, a whole number from 1 to \(top), was expected",
                Comment(rawValue: result.text))
        }
        let label = await Self.onDatabases(ToolCatalog.labelsName, ["label_id": -1], [:], [])
        #expect(label.isError && label.text.contains("from 0 to"))
    }

    // MARK: The window on one message

    private static let longMessage: Message = Fixtures.message(
        id: 77, chatID: 1, chatName: "Ane",
        text: (0..<900).map { "Invented line \(padded($0)) of a very long message." }.joined(separator: "\n"))

    private func messageGet(_ extra: [String: Value] = [:]) async -> (text: String, isError: Bool) {
        await Self.onStore(ToolCatalog.messageGetName, ["message_id": 77], extra) {
            $0.messagesValue = [Self.longMessage]
        }
    }

    private var wholeMessage: String {
        Format(calendar: Fixtures.calendar).messageDetailText(Self.longMessage)
    }

    /// The window of a result: what comes after the notices.
    private func window(_ text: String) -> String {
        guard text.hasPrefix("Characters "), let blank = text.range(of: "\n\n") else { return text }
        return String(text[blank.upperBound...])
    }

    @Test("A long message comes as one default window, announced before the data")
    func defaultMessageWindow() async {
        let whole = wholeMessage
        let size = Configuration.defaultMaxCharacters
        #expect(whole.count > size)
        let result = await messageGet()
        #expect(result.text.hasPrefix("Characters 1–\(size) of \(whole.count). Pass character_offset=\(size) for the rest.\n\n"))
        #expect(window(result.text) == String(whole.prefix(size)))
        #expect(result.text.utf16.count <= ToolStandard.usualPage + 200)
    }

    @Test("Windows chain: each starts where the last ended, and together they are the whole message")
    func messageWindowsChain() async {
        let whole = wholeMessage
        var offset = 0
        var joined = ""
        while offset < whole.count {
            let result = await messageGet(["character_offset": .int(offset), "max_characters": 7_000])
            let part = window(result.text)
            let last = offset + part.count
            let next = last < whole.count ? "Pass character_offset=\(last) for the rest." : "That is all."
            #expect(result.text.hasPrefix("Characters \(offset + 1)–\(last) of \(whole.count). \(next)\n\n"))
            #expect(part.count == min(7_000, whole.count - offset))
            joined += part
            offset = last
        }
        #expect(joined == whole)
    }

    @Test("max_characters at its maximum is used as asked; one past either end is moved and reported")
    func messageWindowBounds() async {
        let whole = wholeMessage
        let maximum = Configuration.maxCharactersRange.upperBound
        #expect(whole.count > maximum)

        let atMaximum = await messageGet(["max_characters": .int(maximum)])
        #expect(!atMaximum.text.contains("is outside"))
        #expect(window(atMaximum.text).count == maximum)
        #expect(atMaximum.text.utf16.count <= ToolStandard.longestResult)

        let over = await messageGet(["max_characters": .int(maximum + 1)])
        #expect(
            over.text.hasPrefix(
                "max_characters=\(maximum + 1) is outside 1–\(maximum); \(maximum) was used.\nCharacters 1–\(maximum) of "))

        let under = await messageGet(["max_characters": 0])
        #expect(under.text.hasPrefix("max_characters=0 is outside 1–\(maximum); 1 was used.\nCharacters 1–1 of "))

        let past = await messageGet(["character_offset": .int(whole.count + 5)])
        #expect(past.text.hasPrefix("Characters 0 of \(whole.count): character_offset=\(whole.count + 5) is past the end. That is all."))
    }

    @Test("A short message is shown whole, with no notice")
    func shortMessageHasNoNotice() async {
        let result = await Self.onStore(ToolCatalog.messageGetName, ["message_id": 10], [:]) {
            $0.messagesValue = [Fixtures.message(id: 10, chatID: 1, chatName: "Ane", text: "hello")]
        }
        #expect(!result.text.contains("Characters"))
        #expect(result.text.hasPrefix("10  "))
    }

    // MARK: The window on a transcript

    /// Recognises the same invented words for any file, as many segments as asked.
    private final class ManySegments: SpeechTranscribing, @unchecked Sendable {
        let count: Int
        init(count: Int) { self.count = count }
        func resolveLocale(_ requested: String?) async throws -> String { "en-US" }
        func transcribe(audio: URL, locale: String) async throws -> [TranscriptSegment] {
            (0..<count).map {
                TranscriptSegment(start: Double($0), end: Double($0) + 1, text: "invented segment \(BoundsTests.padded($0))")
            }
        }
    }

    @Test("A long transcript comes a window at a time, and the windows chain")
    func transcriptWindowsChain() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("whatsapp-bounds-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = directory.appendingPathComponent("Message/Media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let audio = media.appendingPathComponent("note.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let file = try AVAudioFile(forWriting: audio, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
        buffer.frameLength = 1600
        try file.write(from: buffer)

        let engine = ManySegments(count: 1_000)
        let tools = WhatsAppTools(
            store: FakeWhatsAppStore(), mediaFiles: MediaFiles(root: directory.appendingPathComponent("Message")),
            transcription: TranscriptionService(
                mediaFiles: MediaFiles(root: directory.appendingPathComponent("Message")),
                scratchDirectory: directory.appendingPathComponent("cache"), converter: nil, engine: engine),
            calendar: Fixtures.calendar)
        let whole = Format(calendar: Fixtures.calendar).transcriptText(
            Transcription(localeIdentifier: "en-US", durationSeconds: 0.1, segments: try await engine.transcribe(audio: audio, locale: "en-US")))

        var offset = 0
        var joined = ""
        while offset < whole.count {
            let (text, isError) = await WhatsAppMCPCoreTests.call(
                tools, ToolCatalog.audioTranscribeName,
                ["path": .string(audio.path), "language": "en-US", "character_offset": .int(offset)])
            #expect(!isError, Comment(rawValue: text))
            let size = Configuration.defaultMaxCharacters
            let last = min(offset + size, whole.count)
            let next = last < whole.count ? "Pass character_offset=\(last) for the rest." : "That is all."
            #expect(text.hasPrefix("Transcript: characters \(offset + 1)–\(last) of \(whole.count). \(next)\n\n"))
            #expect(text.contains("AUTOMATIC TRANSCRIPTION"))
            let part = String(text[try #require(text.range(of: "errors.\n\n")).upperBound...])
            joined += part
            offset = last
        }
        #expect(joined == whole)
    }

    // MARK: db_query

    @Test("db_query at its row maximum of wide values stays inside the longest result")
    func queryFitsTheLongestResult() async {
        let rows = (0..<300).map { "INSERT INTO ZWIDE VALUES (\($0), printf('%0500d', \($0)))" }
        let result = await Self.onDatabases(
            ToolCatalog.dbQueryName,
            ["db": "Sticker", "sql": "SELECT ZVALUE FROM ZWIDE ORDER BY Z_PK", "limit": .int(Configuration.queryLimitRange.upperBound)],
            [:], [(.sticker, ["CREATE TABLE ZWIDE (Z_PK INTEGER PRIMARY KEY, ZVALUE TEXT)"] + rows)])
        #expect(!result.isError, Comment(rawValue: result.text))
        #expect(result.text.utf16.count <= ToolStandard.longestResult)
        #expect(result.text.hasPrefix("Showing 1–"))
        #expect(result.text.contains("rows; more exist. Pass offset="))

        // With no limit given, reading stops near one usual page.
        let plain = await Self.onDatabases(
            ToolCatalog.dbQueryName, ["db": "Sticker", "sql": "SELECT ZVALUE FROM ZWIDE ORDER BY Z_PK"],
            [:], [(.sticker, ["CREATE TABLE ZWIDE (Z_PK INTEGER PRIMARY KEY, ZVALUE TEXT)"] + rows)])
        #expect(plain.text.utf16.count <= ToolStandard.usualPage + 1_000, "\(plain.text.utf16.count)")
        #expect(plain.text.contains("rows; more exist. Pass offset="))
    }

    @Test("A db_query value over the width is clipped to exactly the width, and the page says so")
    func queryValueIsClipped() async {
        let result = await Self.onDatabases(
            ToolCatalog.dbQueryName, ["db": "Sticker", "sql": "SELECT printf('%0600d', 7) AS v"], [:],
            [(.sticker, ["CREATE TABLE ZEMPTY (Z_PK INTEGER PRIMARY KEY)"])])
        let width = Configuration.cellWidth
        #expect(
            result.text.hasPrefix(
                "Every value is clipped to \(width) characters in each row. Read one in full with db_query, selecting substr(column, start, length).\n\n"),
            Comment(rawValue: result.text))
        #expect(result.text.contains("\n" + String(repeating: "0", count: width - 1) + "…"))
        #expect(!result.text.contains(String(repeating: "0", count: width)))
    }

    // MARK: Time

    /// A store that never answers in time.
    private final class SlowStore: WhatsAppStore, @unchecked Sendable {
        func availability() -> StoreAvailability { .ready }
        func databaseInfo() -> DatabaseInfo { FakeWhatsAppStore().databaseInfo() }
        func chats(matching query: ChatQuery) async throws -> ChatPage {
            try? await Task.sleep(for: .seconds(5))
            return ChatPage(rows: [], total: 0)
        }
        func chat(id: Int64) async throws -> Chat? { nil }
        func messages(matching query: MessageQuery) async throws -> MessagePage { MessagePage(rows: [], total: 0) }
        func message(id: Int64) async throws -> Message? { nil }
        func media(matching query: MessageQuery) async throws -> MessagePage { MessagePage(rows: [], total: 0) }
        func group(chatID: Int64) async throws -> Group? { nil }
    }

    @Test("A call past its deadline is abandoned with an error that says how to ask for less")
    func deadlineIsKept() async {
        let tools = WhatsAppTools(store: SlowStore(), calendar: Fixtures.calendar, timeout: .milliseconds(100))
        let started = ContinuousClock.now
        let (text, isError) = await WhatsAppMCPCoreTests.call(tools, ToolCatalog.chatsName, [:])
        #expect(isError)
        #expect(text.hasPrefix("The call did not finish within"))
        #expect(text.contains("nothing was changed"))
        #expect(ContinuousClock.now - started < .seconds(4))
        #expect(Configuration.callTimeout < ToolStandard.timeLimit)
    }

    // MARK: What the model reads

    @Test("The instructions and every description are within the limit")
    func textsAreWithinTheLimit() {
        #expect(
            ToolStandard.overlongTexts(
                instructions: WhatsAppMCPServer.instructions, catalog: ToolCatalog.all()
            ).isEmpty)
    }

    @Test("Measured as sent: initialize and tools/list stay within the limit")
    func textsAsSent() async throws {
        let handler = WhatsAppMCPServer.handler(
            tools: WhatsAppTools(store: FakeWhatsAppStore(), calendar: Fixtures.calendar))
        let initialize = try #require(
            await handler.respond(
                to: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"bounds","version":"0"}}}"#))
        let answer = try JSONDecoder().decode(Value.self, from: Data(initialize.utf8))
        let instructions = try #require(answer.objectValue?["result"]?.objectValue?["instructions"]?.stringValue)
        #expect(instructions.utf16.count <= ToolStandard.longestDescription, "\(instructions.utf16.count)")

        let list = try #require(await handler.respond(to: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        let tools = try #require(
            try JSONDecoder().decode(Value.self, from: Data(list.utf8))
                .objectValue?["result"]?.objectValue?["tools"]?.arrayValue)
        #expect(tools.count == ToolCatalog.all().count)
        for tool in tools {
            let description = tool.objectValue?["description"]?.stringValue ?? ""
            #expect(
                description.utf16.count <= ToolStandard.longestDescription,
                "\(tool.objectValue?["name"]?.stringValue ?? "?"): \(description.utf16.count)")
        }
    }

    @Test("Every limit sits inside what the standard allows")
    func limitsAreWithinTheStandard() {
        #expect(Configuration.defaultMaxCharacters == ToolStandard.usualPage)
        #expect(Configuration.maxCharactersRange.upperBound <= ToolStandard.longestResult)
        for (range, fallback) in [
            (Configuration.limitRange, Configuration.defaultLimit),
            (Configuration.messageLimitRange, Configuration.defaultMessageLimit),
            (Configuration.tableLimitRange, Configuration.defaultTableLimit),
            (Configuration.schemaLimitRange, Configuration.defaultSchemaLimit),
            (Configuration.queryLimitRange, Configuration.defaultQueryLimit),
            (Configuration.frameRange, Configuration.defaultFrames),
        ] {
            #expect(range.contains(fallback))
        }
    }

    @Test("The README and the manifest state no figure the code could contradict")
    func documentsStateNoBounds() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        let manifest = try String(
            contentsOf: root.appendingPathComponent("extension/manifest.json"), encoding: .utf8)
        // The figures a reader could take for this server's bounds: every limit, default and
        // width it enforces. They are quoted by the tools themselves, from the constants.
        let figures = [
            Configuration.defaultLimit, Configuration.limitRange.upperBound,
            Configuration.defaultMessageLimit, Configuration.messageLimitRange.upperBound,
            Configuration.defaultTableLimit, Configuration.tableLimitRange.upperBound,
            Configuration.defaultSchemaLimit, Configuration.schemaLimitRange.upperBound,
            Configuration.defaultQueryLimit, Configuration.queryLimitRange.upperBound,
            Configuration.textWidth, Configuration.cellWidth, Configuration.participantsWidth,
            Configuration.defaultMaxCharacters, Configuration.maxCharactersRange.upperBound,
            Configuration.frameRange.upperBound, Configuration.defaultFrames,
        ]
        for text in [readme, manifest] {
            for figure in Set(figures) {
                for form in ["\(figure) rows", "\(figure) messages", "\(figure) characters", "\(figure) frames", "up to \(figure)", "at most \(figure)"] {
                    #expect(!text.contains(form), "\(form)")
                }
            }
        }
    }
}
