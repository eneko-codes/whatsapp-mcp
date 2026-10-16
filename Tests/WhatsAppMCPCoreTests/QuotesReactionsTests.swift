import Foundation
import MCP
import SQLite3
import Testing

@testable import WhatsAppMCPCore

/// Everything below is invented. The byte layouts are the ones `MessageExtras` documents,
/// built here by a tiny encoder so a change to the decoder's field numbers fails a test
/// instead of quietly changing what a reaction or a quote means.
private enum Wire {
    static func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return bytes
    }

    static func number(_ field: Int, _ value: UInt64) -> [UInt8] {
        varint(UInt64(field << 3)) + varint(value)
    }

    static func bytes(_ field: Int, _ payload: [UInt8]) -> [UInt8] {
        varint(UInt64(field << 3 | 2)) + varint(UInt64(payload.count)) + payload
    }

    static func string(_ field: Int, _ text: String) -> [UInt8] { bytes(field, Array(text.utf8)) }

    /// A reaction by a named person: receipt field 7 wrapping `{1: {id, address, emoji, ms}}`.
    static func reaction(by address: String, _ emoji: String, at date: Date) -> [UInt8] {
        let inner =
            string(1, "REACTIONID0000000001") + string(2, address) + string(3, emoji)
            + number(4, UInt64(date.timeIntervalSince1970 * 1000)) + number(5, 2) + number(7, 0)
        return bytes(7, bytes(1, inner))
    }

    /// A reaction whose entry names nobody: receipt field 7 wrapping `{2: {id, emoji, ms}}`.
    static func reactionWithoutAddress(_ emoji: String, at date: Date) -> [UInt8] {
        let inner =
            string(1, "REACTIONID0000000002") + string(2, emoji)
            + number(3, UInt64(date.timeIntervalSince1970 * 1000)) + number(4, 1) + number(7, 0)
        return bytes(7, bytes(2, inner))
    }

    /// The per-device receipt entries that sit beside reactions in the same blob.
    static let deviceReceipt: [UInt8] = bytes(2, string(1, "device") + number(2, 1))

    static func quote(stanza: String, participant: String?, text: String?) -> [UInt8] {
        var out = string(5, stanza)
        if let participant { out += string(6, participant) }
        if let text { out += bytes(19, string(1, text)) }
        return out + number(29, 7)
    }

    static func data(_ bytes: [UInt8]) -> Data { Data(bytes) }
}

@Suite("Reactions and quotes: decoding")
struct MessageExtrasDecodingTests {
    private let moment = Fixtures.date(2026, 10, 15, 21, 48)

    private func resolve(_ jid: String) -> Identity {
        Identity(jid: jid, displayName: "Name of \(jid)", profilePicturePath: nil)
    }

    @Test("A reaction names its reactor, its emoji and its time")
    func reactionWithAddress() {
        let blob = Wire.data(
            Wire.deviceReceipt + Wire.reaction(by: "111@lid", "❤️", at: moment))
        let found = MessageExtras.reactions(in: blob, resolve: resolve)
        #expect(found.count == 1)
        #expect(found.first?.emoji == "❤️")
        #expect(found.first?.reactor?.jid == "111@lid")
        #expect(found.first?.reactor?.displayName == "Name of 111@lid")
        #expect(found.first.flatMap(\.date).map { abs($0.timeIntervalSince(moment)) < 1 } == true)
    }

    @Test("An entry that names nobody keeps its emoji and reports no reactor")
    func reactionWithoutAddress() {
        let blob = Wire.data(Wire.reactionWithoutAddress("😮", at: moment))
        let found = MessageExtras.reactions(in: blob, resolve: resolve)
        #expect(found.count == 1)
        #expect(found.first?.emoji == "😮")
        #expect(found.first?.reactor == nil)
    }

    @Test("Several reactions come back oldest first, whatever order they were stored in")
    func reactionsAreOrdered() {
        let blob = Wire.data(
            Wire.reaction(by: "222@lid", "👍", at: moment.addingTimeInterval(60))
                + Wire.reaction(by: "111@lid", "🙏", at: moment))
        let found = MessageExtras.reactions(in: blob, resolve: resolve)
        #expect(found.map(\.emoji) == ["🙏", "👍"])
    }

    @Test("Receipts alone, nothing, or a damaged blob are no reactions")
    func noReactions() {
        #expect(MessageExtras.reactions(in: nil, resolve: resolve).isEmpty)
        #expect(MessageExtras.reactions(in: Wire.data(Wire.deviceReceipt), resolve: resolve).isEmpty)
        // Cut off in the middle of the second entry: the first, intact one is not reported
        // as if it were the whole list.
        let whole = Wire.reaction(by: "111@lid", "👍", at: moment)
            + Wire.reaction(by: "222@lid", "🙏", at: moment)
        let cut = Wire.data(Array(whole.dropLast(5)))
        #expect(MessageExtras.reactions(in: cut, resolve: resolve).isEmpty)
        #expect(MessageExtras.reactions(in: Data([0xFF, 0xFF, 0xFF]), resolve: resolve).isEmpty)
    }

    @Test("Text in the emoji slot is not a reaction, and an impossible time is no time")
    func oddEntries() {
        let notEmoji = Wire.data(Wire.reaction(by: "111@lid", "hello", at: moment))
        #expect(MessageExtras.reactions(in: notEmoji, resolve: resolve).isEmpty)

        let inner =
            Wire.string(1, "REACTIONID0000000003") + Wire.string(2, "111@lid")
            + Wire.string(3, "👍") + Wire.number(4, 12)
        let blob = Wire.data(Wire.bytes(7, Wire.bytes(1, inner)))
        let found = MessageExtras.reactions(in: blob, resolve: resolve)
        #expect(found.count == 1)
        #expect(found.first?.date == nil)
    }

    @Test("A reply carries the quoted id, author and words")
    func quoteIsRead() {
        let blob = Wire.data(
            Wire.quote(stanza: "3AORIGINAL0000000001", participant: "111@lid", text: "see you"))
        let quote = MessageExtras.quote(in: blob)
        #expect(quote?.stanzaID == "3AORIGINAL0000000001")
        #expect(quote?.participant == "111@lid")
        #expect(quote?.text == "see you")
    }

    @Test("A quote without words or author still names its original")
    func quoteWithoutWords() {
        let quote = MessageExtras.quote(
            in: Wire.data(Wire.quote(stanza: "3AORIGINAL0000000001", participant: nil, text: nil)))
        #expect(quote?.stanzaID == "3AORIGINAL0000000001")
        #expect(quote?.participant == nil)
        #expect(quote?.text == nil)
    }

    @Test("A field 5 that is not a message id is not a quote")
    func notAQuote() {
        #expect(MessageExtras.quote(in: nil) == nil)
        #expect(MessageExtras.quote(in: Wire.data(Wire.string(5, "short"))) == nil)
        #expect(MessageExtras.quote(in: Wire.data(Wire.string(5, "has spaces in it, so no"))) == nil)
        #expect(MessageExtras.quote(in: Wire.data(Wire.number(29, 7))) == nil)
        #expect(MessageExtras.quote(in: Data([0xFF, 0xFF])) == nil)
    }
}

// MARK: - Through the store and the tools

private struct QuoteFixture {
    let directory: URL
    var databasePath: String { directory.appendingPathComponent("ChatStorage.sqlite").path }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private func hex(_ bytes: [UInt8]) -> String {
    "X'" + bytes.map { String(format: "%02X", $0) }.joined() + "'"
}

private func makeQuoteFixture(moment: Date) throws -> QuoteFixture {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("whatsapp-quotes-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fixture = QuoteFixture(directory: directory)

    var handle: OpaquePointer?
    guard sqlite3_open(fixture.databasePath, &handle) == SQLITE_OK, let database = handle else {
        throw NSError(domain: "fixture", code: 1)
    }
    defer { sqlite3_close(database) }

    let now = Date().timeIntervalSinceReferenceDate
    let reply = Wire.quote(
        stanza: "3AORIGINAL0000000001", participant: "777@lid", text: "see you at eight")
    let replyToGone = Wire.quote(
        stanza: "3AGONE00000000000001", participant: "999@lid", text: "an old line")
    let reactions =
        Wire.deviceReceipt + Wire.reaction(by: "777@lid", "❤️", at: moment)
        + Wire.reactionWithoutAddress("😮", at: moment.addingTimeInterval(30))
    let groupReactions = Wire.reaction(by: "888@lid", "👍", at: moment)

    var error: UnsafeMutablePointer<CChar>?
    let sql = """
        CREATE TABLE ZWACHATSESSION (
            Z_PK INTEGER PRIMARY KEY, ZCONTACTJID VARCHAR, ZPARTNERNAME VARCHAR,
            ZSESSIONTYPE INTEGER, ZARCHIVED INTEGER, ZHIDDEN INTEGER, ZUNREADCOUNT INTEGER,
            ZLASTMESSAGEDATE TIMESTAMP, ZLASTMESSAGETEXT VARCHAR, ZLASTMESSAGE INTEGER);
        CREATE TABLE ZWAMESSAGE (
            Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INTEGER, ZMESSAGEDATE TIMESTAMP,
            ZSENTDATE TIMESTAMP, ZISFROMME INTEGER, ZGROUPMEMBER INTEGER, ZFROMJID VARCHAR,
            ZTEXT VARCHAR, ZMESSAGETYPE INTEGER, ZSTARRED INTEGER, ZMEDIAITEM INTEGER,
            ZGROUPEVENTTYPE INTEGER, ZMESSAGESTATUS INTEGER, ZMESSAGEERRORSTATUS INTEGER,
            ZSTANZAID VARCHAR, ZMESSAGEINFO INTEGER);
        CREATE TABLE ZWAGROUPMEMBER (
            Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INTEGER, ZCONTACTNAME VARCHAR,
            ZMEMBERJID VARCHAR, ZISADMIN INTEGER, ZISACTIVE INTEGER);
        CREATE TABLE ZWAMEDIAITEM (
            Z_PK INTEGER PRIMARY KEY, ZMESSAGE INTEGER, ZMEDIALOCALPATH VARCHAR,
            ZFILESIZE INTEGER, ZMOVIEDURATION REAL, ZTITLE VARCHAR, ZLATITUDE REAL,
            ZLONGITUDE REAL, ZVCARDNAME VARCHAR, ZVCARDSTRING VARCHAR, ZMEDIAORIGIN INTEGER,
            ZMEDIAURL VARCHAR, ZAUTHORNAME VARCHAR, ZMETADATA BLOB);
        CREATE TABLE ZWAPROFILEPUSHNAME (Z_PK INTEGER PRIMARY KEY, ZJID VARCHAR, ZPUSHNAME VARCHAR);
        CREATE TABLE ZWAMESSAGEINFO (Z_PK INTEGER PRIMARY KEY, ZMESSAGE INTEGER, ZRECEIPTINFO BLOB);

        INSERT INTO ZWACHATSESSION VALUES
            (1, '777@lid', 'Quote Friend', 0, 0, 0, 0, \(now), 'x', 1),
            (2, 'g@g.us', 'Reaction Group', 1, 0, 0, 0, \(now), 'x', 5);
        INSERT INTO ZWAGROUPMEMBER VALUES (1, 2, '', '888@lid', 0, 1);
        INSERT INTO ZWAPROFILEPUSHNAME VALUES (1, '888@lid', 'Grace Invented');

        -- 1: the original, starred, reacted to twice. 2: my reply quoting it. 3: a reply to a
        -- message that is not here. 4: a group message with the same id as message 1, which
        -- a quote in chat 1 must never resolve to. 5: a group message with a reaction.
        INSERT INTO ZWAMESSAGE VALUES
            (1, 1, \(now - 500), NULL, 0, NULL, '777@lid', 'the original', 0, 1, NULL, NULL, 6, 0, '3AORIGINAL0000000001', 10),
            (2, 1, \(now - 400), NULL, 1, NULL, NULL, 'a reply', 0, 0, 1, NULL, 6, 0, '3AREPLY0000000000001', NULL),
            (3, 1, \(now - 300), NULL, 1, NULL, NULL, 'reply to a gone one', 0, 0, 2, NULL, 6, 0, '3AREPLY0000000000002', NULL),
            (4, 2, \(now - 200), NULL, 0, 1, '888@lid', 'same id, other chat', 0, 0, NULL, NULL, 6, 0, '3AORIGINAL0000000001', NULL),
            (5, 2, \(now - 100), NULL, 0, 1, '888@lid', 'a group message', 0, 1, NULL, NULL, 6, 0, '3AGROUP00000000000001', 11);
        INSERT INTO ZWAMEDIAITEM (Z_PK, ZMESSAGE, ZMETADATA) VALUES
            (1, 2, \(hex(reply))), (2, 3, \(hex(replyToGone)));
        INSERT INTO ZWAMESSAGEINFO VALUES (10, 1, \(hex(reactions))), (11, 5, \(hex(groupReactions)));
        """
    guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
        let detail = error.map { String(cString: $0) } ?? "unknown"
        sqlite3_free(error)
        throw NSError(domain: "fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: detail])
    }
    return fixture
}

@Suite("Reactions, quotes and stars through the store and the tools")
struct QuotesReactionsStoreTests {
    private let moment = Fixtures.date(2026, 10, 15, 21, 48)

    private func tools(_ fixture: QuoteFixture) -> WhatsAppTools {
        WhatsAppTools(
            store: SystemWhatsAppStore(path: fixture.databasePath), calendar: Fixtures.calendar)
    }

    @Test("A reply knows which message it quotes in its own chat, never one with the same id elsewhere")
    func quoteResolvesInsideItsChat() async throws {
        let fixture = try makeQuoteFixture(moment: moment)
        defer { fixture.remove() }
        let message = try await SystemWhatsAppStore(path: fixture.databasePath).message(id: 2)
        let quote = try #require(message?.quote)
        #expect(quote.localMessageID == 1)
        #expect(quote.quotedIsFromMe == false)
        #expect(quote.text == "see you at eight")
        #expect(quote.author?.displayName == "Quote Friend")
    }

    @Test("A reply to a message that is not on this Mac keeps the quoted words")
    func quoteWithoutOriginal() async throws {
        let fixture = try makeQuoteFixture(moment: moment)
        defer { fixture.remove() }
        let message = try await SystemWhatsAppStore(path: fixture.databasePath).message(id: 3)
        let quote = try #require(message?.quote)
        #expect(quote.localMessageID == nil)
        #expect(quote.text == "an old line")
    }

    @Test("Reactions carry their reactor, named from the chat or the profile table")
    func reactionsAreNamed() async throws {
        let fixture = try makeQuoteFixture(moment: moment)
        defer { fixture.remove() }
        let store = SystemWhatsAppStore(path: fixture.databasePath)
        let direct = try #require(try await store.message(id: 1)).reactions
        #expect(direct.map(\.emoji) == ["❤️", "😮"])
        #expect(direct.first?.reactor?.displayName == "Quote Friend")
        #expect(direct.last?.reactor == nil)

        let group = try #require(try await store.message(id: 5)).reactions
        #expect(group.first?.reactor?.displayName == "Grace Invented")
    }

    @Test("message_get shows the quote and who reacted, and says when nobody is recorded")
    func detailShowsBoth() async throws {
        let fixture = try makeQuoteFixture(moment: moment)
        defer { fixture.remove() }
        let (reply, _) = await call(tools(fixture), ToolCatalog.messageGetName, ["message_id": .int(2)])
        #expect(reply.contains("replies to: message 1 (Quote Friend  777@lid)"))
        #expect(reply.contains("see you at eight"))

        let (gone, _) = await call(tools(fixture), ToolCatalog.messageGetName, ["message_id": .int(3)])
        #expect(gone.contains("replies to: a message that is not on this Mac"))

        let (original, _) = await call(
            tools(fixture), ToolCatalog.messageGetName, ["message_id": .int(1)])
        #expect(original.contains("❤️  Quote Friend  777@lid"))
        #expect(original.contains("😮  reactor not recorded in this entry"))
    }

    @Test("chat_get marks replies and reactions on the line and explains the marks once")
    func listLinesCarryMarks() async throws {
        let fixture = try makeQuoteFixture(moment: moment)
        defer { fixture.remove() }
        let (text, isError) = await call(tools(fixture), ToolCatalog.chatGetName, ["chat_id": .int(1)])
        #expect(!isError, Comment(rawValue: text))
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.contains { $0.hasPrefix("2  ") && $0.contains("↩1") })
        #expect(lines.contains { $0.hasPrefix("3  ") && $0.hasSuffix("↩") })
        #expect(lines.contains { $0.hasPrefix("1  ") && $0.contains("[❤️ 😮]") })
        #expect(text.contains("↩N is a reply to message N"))
    }

    @Test("Starred messages of every chat are listed without a phrase")
    func starredAcrossChats() async throws {
        let fixture = try makeQuoteFixture(moment: moment)
        defer { fixture.remove() }
        let (text, isError) = await call(
            tools(fixture), ToolCatalog.searchName, ["starred_only": .bool(true)])
        #expect(!isError, Comment(rawValue: text))
        #expect(text.contains("2 matching"))
        #expect(text.contains("the original"))
        #expect(text.contains("a group message"))
        #expect(!text.contains("a reply"))
    }

    @Test("A search with neither a phrase nor starred_only is refused, not answered with everything")
    func searchNeedsSomething() async throws {
        let fixture = try makeQuoteFixture(moment: moment)
        defer { fixture.remove() }
        let (text, isError) = await call(tools(fixture), ToolCatalog.searchName, [:])
        #expect(isError)
        #expect(text.contains("starred_only"))
    }
}
