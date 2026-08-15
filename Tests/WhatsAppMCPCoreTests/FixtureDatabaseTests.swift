import Foundation
import SQLite3
import Testing

@testable import WhatsAppMCPCore

/// Exercises `SystemWhatsAppStore` — the one type that speaks SQL — against a database this
/// suite builds itself in a temporary directory.
///
/// Every chat, message, name and file below is invented. The owner's real store is never
/// opened, never copied and never read; that is the rule this file exists to honour while
/// still covering the code below the `WhatsAppStore` seam, which the in-memory fake cannot
/// reach and which is where the SQL and the column indices actually live.
///
/// Several rows here exist only to reproduce a trap the real schema sets — a photo whose
/// stored "latitude" is a pixel height, a sticker carrying a base64 key in the vCard
/// column, a profile picture path that is not a path, a message with a dozen link-preview
/// rows. Each one fails loudly if the gate that handles it is ever dropped.
private struct Fixture {
    let directory: URL

    var databasePath: String {
        directory.appendingPathComponent("ChatStorage.sqlite").path
    }

    /// WhatsApp resolves a stored media path against `Message/` beside the database.
    var mediaDirectory: URL {
        directory.appendingPathComponent("Message/Media")
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Seconds since 2001-01-01, which is how Core Data — and therefore WhatsApp — stores a date.
private let reference = Date().timeIntervalSinceReferenceDate

/// The offset WhatsApp adds to hold a chat at the top of its own ordering. Five thousand
/// years is the smallest one observed on a real library.
private let pinOffset: TimeInterval = 5000 * 365.25 * 24 * 60 * 60

/// A real value seen in `ZPUSHNAME`: base64, not a name. Used here so a regression that
/// starts reading that column again shows up as a sender literally called this.
private let pushNameBlob = "CNXy9s8GIAA="

/// The shape `ZVCARDNAME` and `ZVCARDSTRING` carry on every type that is not a contact
/// card — a fixed-length base64 key, on thousands of rows in a real library.
private let vcardBlob = "S1QxMjM0NTY3ODkwYWJjZGVmZ2hpamtsbW5vcHFyc3R1dg=="

/// `ZWAPROFILEPICTUREITEM.ZPATH` is not always a path: 109 of 386 rows on the measured
/// library hold a blob of this shape instead.
private let picturePathBlob = "CAASEQoJjBKUEAgYworB1w0gChwKFjIwNDIzMjgxMTFhYmNkZWZnaGlqaw=="

private func execute(_ database: OpaquePointer, _ sql: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
        let detail = error.map { String(cString: $0) } ?? "unknown"
        sqlite3_free(error)
        throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
    }
}

private func makeFixture() throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("whatsapp-fixture-\(UUID().uuidString)")
    let fixture = Fixture(directory: directory)
    try FileManager.default.createDirectory(
        at: fixture.mediaDirectory.appendingPathComponent("Profile"),
        withIntermediateDirectories: true)

    // One media file exists; the other deliberately does not, standing in for a row whose
    // file WhatsApp has evicted.
    try Data("not a real image".utf8)
        .write(to: fixture.mediaDirectory.appendingPathComponent("present.jpg"))
    try Data("not a real portrait".utf8)
        .write(to: fixture.mediaDirectory.appendingPathComponent("Profile/ada.jpg"))

    var handle: OpaquePointer?
    guard sqlite3_open(fixture.databasePath, &handle) == SQLITE_OK, let database = handle else {
        throw NSError(domain: "fixture", code: 2)
    }
    defer { sqlite3_close(database) }

    // Only the columns the queries name. A fixture that mirrored the whole of WhatsApp's
    // schema would be a copy of something nobody should be copying.
    try execute(
        database,
        """
        CREATE TABLE ZWACHATSESSION (
            Z_PK INTEGER PRIMARY KEY, ZCONTACTJID VARCHAR, ZPARTNERNAME VARCHAR,
            ZSESSIONTYPE INTEGER, ZARCHIVED INTEGER, ZHIDDEN INTEGER, ZUNREADCOUNT INTEGER,
            ZLASTMESSAGEDATE TIMESTAMP, ZLASTMESSAGETEXT VARCHAR, ZLASTMESSAGE INTEGER);
        CREATE TABLE ZWAMESSAGE (
            Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INTEGER, ZMESSAGEDATE TIMESTAMP,
            ZSENTDATE TIMESTAMP, ZISFROMME INTEGER, ZGROUPMEMBER INTEGER,
            ZPUSHNAME VARCHAR, ZFROMJID VARCHAR, ZTEXT VARCHAR, ZMESSAGETYPE INTEGER,
            ZSTARRED INTEGER, ZMEDIAITEM INTEGER, ZGROUPEVENTTYPE INTEGER,
            ZMESSAGESTATUS INTEGER, ZMESSAGEERRORSTATUS INTEGER, ZSTANZAID VARCHAR);
        CREATE TABLE ZWAGROUPMEMBER (
            Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INTEGER, ZCONTACTNAME VARCHAR,
            ZMEMBERJID VARCHAR, ZISADMIN INTEGER, ZISACTIVE INTEGER, ZFIRSTNAME VARCHAR);
        CREATE TABLE ZWAMEDIAITEM (
            Z_PK INTEGER PRIMARY KEY, ZMESSAGE INTEGER, ZMEDIALOCALPATH VARCHAR,
            ZFILESIZE INTEGER, ZMOVIEDURATION REAL, ZTITLE VARCHAR,
            ZLATITUDE REAL, ZLONGITUDE REAL, ZVCARDNAME VARCHAR, ZVCARDSTRING VARCHAR,
            ZMEDIAORIGIN INTEGER, ZMEDIAURL VARCHAR, ZAUTHORNAME VARCHAR);
        CREATE TABLE ZWAPROFILEPUSHNAME (
            Z_PK INTEGER PRIMARY KEY, ZJID VARCHAR, ZPUSHNAME VARCHAR);
        CREATE TABLE ZWAPROFILEPICTUREITEM (
            Z_PK INTEGER PRIMARY KEY, ZJID VARCHAR, ZPATH VARCHAR, ZPICTUREID VARCHAR);
        CREATE TABLE ZWAMESSAGEDATAITEM (
            Z_PK INTEGER PRIMARY KEY, ZMESSAGE INTEGER, ZINDEX INTEGER, ZTYPE INTEGER,
            ZCONTENT1 VARCHAR, ZMATCHEDTEXT VARCHAR, ZTITLE VARCHAR, ZSUMMARY VARCHAR);
        CREATE TABLE ZWAGROUPINFO (
            Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INTEGER, ZCREATIONDATE TIMESTAMP,
            ZCREATORJID VARCHAR, ZSUBJECTTIMESTAMP TIMESTAMP, ZSUBJECTOWNERJID VARCHAR,
            ZPICTUREID VARCHAR);
        """)

    let ordinary = reference - 60
    let pinnedReal = reference - 3600
    let groupLatest = reference - 110

    try execute(
        database,
        """
        INSERT INTO ZWACHATSESSION
            (Z_PK, ZCONTACTJID, ZPARTNERNAME, ZSESSIONTYPE, ZARCHIVED, ZHIDDEN, ZUNREADCOUNT,
             ZLASTMESSAGEDATE, ZLASTMESSAGETEXT, ZLASTMESSAGE)
        VALUES
            (1, '111@lid', 'Ada Lovelace', 0, 0, 0, 0, \(ordinary), 'hello', 10),
            (2, '222@lid', 'Pinned Friend', 0, 0, 0, 0, \(pinnedReal + pinOffset), 'pinned', 20),
            (3, 'g@g.us',  'Test Group',    1, 0, 0, 0, \(groupLatest), 'group hello', 31),
            (4, 'status',  'Status',        3, 0, 0, 0, \(reference + pinOffset), NULL, NULL),
            (5, '555@lid', 'Hidden Chat',   0, 0, 1, 0, \(reference - 300), 'quiet', 111);

        -- ZCONTACTNAME is an empty string on every row of a real library, never NULL.
        -- The fixture copies that exactly, because a NULL here would let a `?? ` fallback
        -- pass a test that the real database fails. ZFIRSTNAME copies the other half of
        -- that trap: a five-character key that is not anybody's first name.
        INSERT INTO ZWAGROUPMEMBER
            (Z_PK, ZCHATSESSION, ZCONTACTNAME, ZMEMBERJID, ZISADMIN, ZISACTIVE, ZFIRSTNAME)
        VALUES
            (1, 3, '', '333@lid', 1, 1, 'CNXy9'),
            (2, 3, '', '444@lid', 0, 1, 'Bk2Lp'),
            -- Never a sender in this fixture's messages, only a member row: covers a
            -- roster entry with no matching profile name and no message to fall back on.
            (3, 3, '', '666@lid', 0, 0, NULL);

        -- The table that actually names a group sender — and, for messages 50/60/61
        -- below, the only source that can resolve a mention or a group event's party.
        -- Member 2 is deliberately absent from it: on a real library some senders
        -- resolve and some do not.
        INSERT INTO ZWAPROFILEPUSHNAME (Z_PK, ZJID, ZPUSHNAME)
        VALUES (1, '333@lid', 'Grace Hopper'), (2, '99020605243425@lid', 'Ane');

        -- One real relative path, and one row holding the blob that a third of these rows
        -- carry on a real library. Handing that blob over as a path is the failure this
        -- table's gate exists for.
        INSERT INTO ZWAPROFILEPICTUREITEM (Z_PK, ZJID, ZPATH, ZPICTUREID)
        VALUES
            (1, '111@lid', 'Media/Profile/ada.jpg', 'pic-ada'),
            (2, '333@lid', '\(picturePathBlob)', 'pic-grace');

        INSERT INTO ZWAMESSAGE
            (Z_PK, ZCHATSESSION, ZMESSAGEDATE, ZSENTDATE, ZISFROMME, ZGROUPMEMBER, ZPUSHNAME,
             ZFROMJID, ZTEXT, ZMESSAGETYPE, ZSTARRED, ZMEDIAITEM, ZGROUPEVENTTYPE,
             ZMESSAGESTATUS, ZMESSAGEERRORSTATUS, ZSTANZAID)
        VALUES
            (10, 1, \(ordinary), NULL, 0, NULL, '\(pushNameBlob)', '111@lid', 'hello', 0, 0, NULL, NULL, 6, 0, NULL),
            (20, 2, \(pinnedReal), NULL, 0, NULL, '\(pushNameBlob)', '222@lid', 'pinned', 0, 0, NULL, NULL, 6, 0, NULL),
            (30, 3, \(reference - 120), NULL, 0, 1, '\(pushNameBlob)', '333@lid', 'group hello', 0, 0, NULL, NULL, 6, 0, NULL),
            (31, 3, \(groupLatest), NULL, 0, 2, '\(pushNameBlob)', '444@lid', 'anon hello', 0, 0, NULL, NULL, 6, 0, NULL),
            (40, 1, \(reference - 50), NULL, 0, NULL, '\(pushNameBlob)', '111@lid', NULL, 1, 0, 1, NULL, 6, 0, NULL),
            (41, 1, \(reference - 40), NULL, 0, NULL, '\(pushNameBlob)', '111@lid', NULL, 1, 0, 2, NULL, 6, 0, NULL),
            -- A mention naming a known LID, and one naming nobody the store has ever seen.
            (50, 3, \(reference - 90), NULL, 0, NULL, '\(pushNameBlob)', '333@lid',
             'ping @99020605243425 are you free?', 0, 0, NULL, NULL, 6, 0, NULL),
            (51, 3, \(reference - 80), NULL, 0, NULL, '\(pushNameBlob)', '333@lid',
             'ping @12345678901234 anyone?', 0, 0, NULL, NULL, 6, 0, NULL),
            -- A group event: actor resolves through ZWAPROFILEPUSHNAME, subject does not
            -- (member 444@lid is only ever named in ZWAGROUPMEMBER, which is not consulted
            -- for a group event's subject).
            (60, 3, \(reference - 70), NULL, 0, NULL, NULL, '333@lid', '444@lid', 6, 0, NULL, 2, 6, 0, NULL),
            -- A group event whose actor has no profile name at all: the phone-number JID
            -- domain resolves on its own, and a null ZTEXT means no subject to report.
            (61, 3, \(reference - 65), NULL, 0, NULL, NULL, '34600111222@s.whatsapp.net', NULL,
             10, 0, NULL, 3, 6, 0, NULL),
            -- A shared location and a shared contact card: both are messages whose entire
            -- content lives on the joined media row, not in ZTEXT.
            (70, 1, \(reference - 30), NULL, 0, NULL, NULL, '111@lid', NULL, 5, 0, 3, NULL, 6, 0, NULL),
            (71, 1, \(reference - 20), NULL, 0, NULL, NULL, '111@lid', NULL, 4, 0, 4, NULL, 6, 0, NULL),
            -- A group event carrying no subject in ZTEXT, which is the common case on a
            -- real library: 145 of 202 such rows there have none.
            (80, 3, \(reference - 200), NULL, 0, NULL, NULL, '333@lid', NULL, 6, 0, NULL, 5, 6, 0, NULL),
            -- A type-14 row, ZTEXT holding a JID rather than anything recoverable, as
            -- WhatsApp leaves one. Nothing in the schema links it to what it replaced.
            (91, 1, \(reference - 10), NULL, 0, NULL, NULL, '111@lid', '111@lid', 14, 0, NULL, 2, 6, 0, NULL),
            -- Two type-3 messages. ZMEDIAORIGIN is the only thing separating something
            -- somebody recorded from a file they attached.
            (100, 1, \(reference - 220), NULL, 0, NULL, NULL, '111@lid', NULL, 3, 0, 5, NULL, 6, 0, NULL),
            (101, 1, \(reference - 210), NULL, 0, NULL, NULL, '111@lid', NULL, 3, 0, 6, NULL, 6, 0, NULL),
            -- A sticker, whose media row carries the vCard blob every non-contact type does.
            (102, 1, \(reference - 205), NULL, 0, NULL, NULL, '111@lid', NULL, 15, 0, 7, NULL, 6, 0, NULL),
            -- A plain text message with a link preview, and a document that failed to send.
            (110, 1, \(reference - 195), NULL, 0, NULL, NULL, '111@lid', 'look at this', 0, 0, NULL, NULL, 6, 0, NULL),
            (120, 1, \(reference - 190), \(reference - 189), 1, NULL, NULL, NULL, NULL, 8, 1, 8, NULL, 8, 813362195, NULL),
            (111, 5, \(reference - 300), NULL, 0, NULL, NULL, '555@lid', 'quiet', 0, 0, NULL, NULL, 6, 0, NULL);

        -- The photo rows copy what a real library puts in these columns, which is NOT a
        -- position: Core Data reuses ZLATITUDE/ZLONGITUDE for pixel dimensions on every
        -- media type except a location, and ZVCARDNAME/ZVCARDSTRING for a base64 key.
        -- All of them are here so a regression that drops a type gate reports message 40
        -- as a place at latitude 3024, or the sticker as somebody's contact card, and
        -- fails loudly instead of shipping.
        INSERT INTO ZWAMEDIAITEM
            (Z_PK, ZMESSAGE, ZMEDIALOCALPATH, ZFILESIZE, ZMOVIEDURATION, ZTITLE,
             ZLATITUDE, ZLONGITUDE, ZVCARDNAME, ZVCARDSTRING, ZMEDIAORIGIN, ZMEDIAURL,
             ZAUTHORNAME)
        VALUES
            (1, 40, 'Media/present.jpg', 16, 0, 'invoice.pdf', 4032, 3024,
             '\(vcardBlob)', '\(vcardBlob)', 0, 'https://mmg.whatsapp.net/invented', NULL),
            (2, 41, 'Media/evicted.jpg', 99, 0, NULL, 1280, 960,
             '\(vcardBlob)', '\(vcardBlob)', 0, NULL, NULL),
            (3, 70, NULL, NULL, 0, NULL, 43.318334, -1.981231, NULL, NULL, 0, NULL, NULL),
            (4, 71, NULL, NULL, 0, NULL, 0, 0, 'Invented Contact',
             'BEGIN:VCARD\nFN:Invented Contact\nEND:VCARD', 0, NULL, NULL),
            (5, 100, NULL, 4096, 14, NULL, 0, 0, NULL, '\(vcardBlob)', 1, NULL, NULL),
            (6, 101, NULL, 8192, 96, 'a-song.m4a', 0, 0, NULL, '\(vcardBlob)', 0, NULL, NULL),
            (7, 102, NULL, 512, 0, NULL, 512, 512, '\(vcardBlob)', '\(vcardBlob)', 0, NULL, NULL),
            -- ZMOVIEDURATION = 2 on a PDF. On a real library documents carry 0 to 472
            -- there, 1/2/3/4 by far the commonest — a page count. Read as seconds this
            -- contract becomes a two-second clip.
            (8, 120, NULL, 20480, 2, 'contract.pdf', 0, 0, NULL, '\(vcardBlob)', 0,
             'https://mmg.whatsapp.net/invented-doc', 'Invented Author');

        -- Twelve rows for one message, which is what a real library holds for a message
        -- carrying several links. Joined on the message alone this multiplies message 110
        -- by twelve and every count above it is wrong.
        INSERT INTO ZWAMESSAGEDATAITEM
            (Z_PK, ZMESSAGE, ZINDEX, ZTYPE, ZCONTENT1, ZMATCHEDTEXT, ZTITLE, ZSUMMARY)
        VALUES
            (1, 110, 0, 0, 'https://example.com', 'https://example.com',
             'Title of the page', 'A summary of the page'),
            (2, 110, 1, 0, 'https://example.org', 'https://example.org', NULL, NULL),
            (3, 110, 2, 0, 'https://example.net', 'https://example.net', NULL, NULL),
            (4, 110, 3, 0, 'https://example.com/4', 'https://example.com/4', NULL, NULL),
            (5, 110, 4, 0, 'https://example.com/5', 'https://example.com/5', NULL, NULL),
            (6, 110, 5, 0, 'https://example.com/6', 'https://example.com/6', NULL, NULL),
            (7, 110, 6, 0, 'https://example.com/7', 'https://example.com/7', NULL, NULL),
            (8, 110, 7, 0, 'https://example.com/8', 'https://example.com/8', NULL, NULL),
            (9, 110, 8, 0, 'https://example.com/9', 'https://example.com/9', NULL, NULL),
            (10, 110, 9, 0, 'https://example.com/10', 'https://example.com/10', NULL, NULL),
            (11, 110, 10, 0, 'https://example.com/11', 'https://example.com/11', NULL, NULL),
            (12, 110, 11, 0, 'https://example.com/12', 'https://example.com/12', NULL, NULL);

        INSERT INTO ZWAGROUPINFO
            (Z_PK, ZCHATSESSION, ZCREATIONDATE, ZCREATORJID, ZSUBJECTTIMESTAMP, ZSUBJECTOWNERJID, ZPICTUREID)
        VALUES (1, 3, \(reference - 999_999), '333@lid', \(reference - 500), '444@lid', 'pic-abc');

        """)

    return fixture
}

@Suite("SystemWhatsAppStore against a fixture database")
struct FixtureDatabaseTests {

    @Test("The fixture satisfies the schema check, so the rest of the suite means something")
    func schemaIsAccepted() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        #expect(SystemWhatsAppStore(path: fixture.databasePath).availability() == .ready)
    }

    // MARK: Pinned and hidden chats

    @Test("A pinned chat reports the real date, never the inflated sort key")
    func pinnedChatReportsRealDate() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = SystemWhatsAppStore(path: fixture.databasePath)

        let chats = try await store.chats(matching: ChatQuery())
        let pinned = try #require(chats.first { $0.id == 2 })

        #expect(pinned.isPinned)
        let date = try #require(pinned.lastMessageDate)
        // The bug this pins down rendered the year 7026. A whole millennium of error is not
        // a rounding question, so a one-second tolerance is generous and still decisive.
        #expect(abs(date.timeIntervalSinceReferenceDate - (reference - 3600)) < 1)
    }

    @Test("An ordinary chat is not reported as pinned")
    func ordinaryChatIsNotPinned() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = SystemWhatsAppStore(path: fixture.databasePath)

        let chats = try await store.chats(matching: ChatQuery())
        let ordinary = try #require(chats.first { $0.id == 1 })

        #expect(!ordinary.isPinned)
        let date = try #require(ordinary.lastMessageDate)
        #expect(abs(date.timeIntervalSinceReferenceDate - (reference - 60)) < 1)
    }

    @Test("A pinned chat with no last message has no date rather than a fictional one")
    func pinnedChatWithoutMessageHasNoDate() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = SystemWhatsAppStore(path: fixture.databasePath)

        let chats = try await store.chats(matching: ChatQuery(kinds: [.status]))
        let status = try #require(chats.first { $0.id == 4 })

        #expect(status.isPinned)
        #expect(status.lastMessageDate == nil)
    }

    @Test("No chat is ever dated beyond now, whatever the sort key says")
    func noChatIsDatedInTheFuture() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = SystemWhatsAppStore(path: fixture.databasePath)

        for chat in try await store.chats(matching: ChatQuery(includeArchived: true)) {
            if let date = chat.lastMessageDate {
                #expect(date.timeIntervalSinceNow < 1, "chat \(chat.id) is dated in the future")
            }
        }
    }

    @Test("A hidden chat is left out until it is asked for, and is flagged when it appears")
    func hiddenChatIsExcludedByDefault() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = SystemWhatsAppStore(path: fixture.databasePath)

        let plain = try await store.chats(matching: ChatQuery())
        #expect(!plain.contains { $0.id == 5 })

        let included = try await store.chats(matching: ChatQuery(includeHidden: true))
        let hidden = try #require(included.first { $0.id == 5 })
        #expect(hidden.isHidden == true)
    }

    // MARK: Sender identity

    @Test("A one-to-one sender is the chat, never the ZPUSHNAME blob")
    func oneToOneSenderIsTheChat() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = SystemWhatsAppStore(path: fixture.databasePath)

        let page = try await store.messages(matching: MessageQuery(chatID: 1))
        let message = try #require(page.rows.first { $0.id == 10 })

        #expect(message.sender?.displayName == "Ada Lovelace")
    }

    @Test("A group sender is named from the profile table when the member row is blank")
    func groupSenderComesFromProfileTable() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = SystemWhatsAppStore(path: fixture.databasePath)

        let page = try await store.messages(matching: MessageQuery(chatID: 3))
        let message = try #require(page.rows.first { $0.id == 30 })

        #expect(message.sender?.displayName == "Grace Hopper")
    }

    @Test("An empty member name is treated as absent, never shown as a blank sender")
    func emptyMemberNameIsNotABlankSender() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = SystemWhatsAppStore(path: fixture.databasePath)

        let page = try await store.messages(matching: MessageQuery(limit: 100))
        for row in page.rows {
            // A sender rendered as "" reads as a message from nobody. NULLIF is what keeps
            // the empty string from winning a COALESCE it should have lost.
            #expect(row.sender?.displayName != "", "message \(row.id) has a blank sender")
        }
    }

    @Test("A group member WhatsApp has no name for is identified by address, not as the group")
    func unnamedGroupMemberFallsBackToAddress() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = SystemWhatsAppStore(path: fixture.databasePath)

        let page = try await store.messages(matching: MessageQuery(chatID: 3))
        let message = try #require(page.rows.first { $0.id == 31 })

        // Naming it after the group would attribute one member's words to everyone in it.
        #expect(message.sender?.displayName != "Test Group")
        #expect(message.sender?.jid == "444@lid")
        #expect(message.sender?.kind == .lid)
    }

    @Test("ZPUSHNAME never reaches a sender name, in any chat")
    func pushNameBlobNeverSurfaces() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = SystemWhatsAppStore(path: fixture.databasePath)

        let page = try await store.messages(matching: MessageQuery(limit: 100))
        #expect(!page.rows.isEmpty)
        for row in page.rows {
            #expect(row.sender?.displayName != pushNameBlob)
            #expect(row.sender?.jid != pushNameBlob)
        }
    }

    // MARK: Profile pictures

    @Test("A profile picture is reported only when the stored value is a path to a real file")
    func profilePictureResolvesOnlyWhenItIsAPath() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = SystemWhatsAppStore(path: fixture.databasePath)

        let page = try await store.messages(matching: MessageQuery(limit: 100))
        let named = try #require(page.rows.first { $0.id == 10 })
        let path = try #require(named.sender?.profilePicturePath)
        #expect(FileManager.default.fileExists(atPath: path))

        // 333@lid's row holds a blob rather than a path. Reported as a file, it would send
        // a caller looking for something that was never there.
        let group = try await store.messages(matching: MessageQuery(chatID: 3, limit: 100))
        let blobbed = try #require(group.rows.first { $0.id == 30 })
        #expect(blobbed.sender?.profilePicturePath == nil)
    }

    // MARK: Attachments

    @Test("A downloaded file is reported as an absolute path that opens")
    func mediaPathIsAbsoluteAndReal() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = SystemWhatsAppStore(path: fixture.databasePath)

        let page = try await store.media(matching: MessageQuery(kinds: MediaKind.allCases))
        let present = try #require(page.rows.first { $0.id == 40 })
        guard case .attachment(let attachment) = present.body else {
            Issue.record("message 40 is not an attachment")
            return
        }
        let path = try #require(attachment.localPath)

        #expect(path.hasPrefix("/"), "a relative path resolves against nothing for the caller")
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("A row whose file WhatsApp has evicted reports no path at all")
    func evictedMediaReportsNoPath() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = SystemWhatsAppStore(path: fixture.databasePath)

        let page = try await store.media(matching: MessageQuery(kinds: MediaKind.allCases))
        let evicted = try #require(page.rows.first { $0.id == 41 })
        guard case .attachment(let attachment) = evicted.body else {
            Issue.record("message 41 is not an attachment")
            return
        }
        // The tools promise that a path present means the file is on this Mac. A path to
        // something that is not there would break exactly that promise.
        #expect(attachment.localPath == nil)
    }

    /// The one distinction `ZMESSAGETYPE` cannot make on its own, and the one a reader of a
    /// conversation cares about most.
    @Test("A voice note and an audio file share a type and are still told apart")
    func voiceNoteIsDistinguishedFromAudioFile() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = SystemWhatsAppStore(path: fixture.databasePath)

        let page = try await store.messages(matching: MessageQuery(chatID: 1, limit: 100))

        guard case .attachment(let recorded) = try #require(page.rows.first { $0.id == 100 }).body
        else {
            Issue.record("message 100 is not an attachment")
            return
        }
        #expect(recorded.kind == .voiceNote)
        #expect(recorded.duration == 14)

        guard case .attachment(let attached) = try #require(page.rows.first { $0.id == 101 }).body
        else {
            Issue.record("message 101 is not an attachment")
            return
        }
        #expect(attached.kind == .audioFile)
        #expect(attached.title == "a-song.m4a")
    }

    @Test("A media filter on voice notes leaves the audio file behind")
    func voiceNoteFilterExcludesAudioFile() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = SystemWhatsAppStore(path: fixture.databasePath)

        let page = try await store.media(matching: MessageQuery(kinds: [.voiceNote]))
        #expect(page.rows.map(\.id) == [100])
        #expect(page.total == 1)
    }

    @Test("A sticker is reported as a sticker, with no file asked of the caller")
    func stickerIsItsOwnKind() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = SystemWhatsAppStore(path: fixture.databasePath)

        let page = try await store.media(matching: MessageQuery(kinds: [.sticker]))
        let sticker = try #require(page.rows.first)
        guard case .attachment(let attachment) = sticker.body else {
            Issue.record("the sticker is not an attachment")
            return
        }
        #expect(attachment.kind == .sticker)
        #expect(attachment.localPath == nil)
    }

    @Test("A document carries its filename, author and WhatsApp URL")
    func documentCarriesItsMetadata() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = SystemWhatsAppStore(path: fixture.databasePath)

        let message = try #require(try await store.message(id: 120))
        guard case .attachment(let attachment) = message.body else {
            Issue.record("message 120 is not an attachment")
            return
        }
        #expect(attachment.kind == .document)
        #expect(attachment.title == "contract.pdf")
        #expect(attachment.author == "Invented Author")
        #expect(attachment.remoteURL == "https://mmg.whatsapp.net/invented-doc")
        // The media row says 2 in the duration column, and on a document that is not
        // seconds. Reported, a 20 kB contract reads as a two-second clip.
        #expect(attachment.duration == nil)
    }

    // MARK: Link previews

    @Test("A message with a dozen preview rows is still one message")
    func linkPreviewDoesNotMultiplyMessages() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = SystemWhatsAppStore(path: fixture.databasePath)

        let page = try await store.messages(matching: MessageQuery(chatID: 1, limit: 100))
        // Twelve ZWAMESSAGEDATAITEM rows point at message 110. Without the ZINDEX gate it
        // comes back twelve times and the total above it is wrong by eleven.
        #expect(page.rows.filter { $0.id == 110 }.count == 1)
        #expect(page.total == page.rows.count)
    }

    @Test("A link preview reaches the message as its url, title and summary")
    func linkPreviewIsRead() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = SystemWhatsAppStore(path: fixture.databasePath)

        let message = try #require(try await store.message(id: 110))
        guard case .link(let preview) = message.body else {
            Issue.record("message 110 is not a link")
            return
        }
        #expect(preview.url == "https://example.com")
        #expect(preview.title == "Title of the page")
        #expect(preview.summary == "A summary of the page")
        // The words the person actually typed are not the preview and must survive it.
        #expect(message.text == "look at this")
    }

    // MARK: Mentions

    @Test("A mention naming a known LID is resolved to that name, id kept alongside")
    func mentionResolvesToKnownName() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = SystemWhatsAppStore(path: fixture.databasePath)

        let page = try await store.messages(matching: MessageQuery(chatID: 3))
        let message = try #require(page.rows.first { $0.id == 50 })

        #expect(message.text == "ping @Ane (99020605243425) are you free?")
        #expect(message.mentions.count == 1)
        #expect(message.mentions.first?.name == "Ane")
        #expect(message.mentions.first?.jid == "99020605243425@lid")
    }

    @Test("A mention naming an unknown LID is left as written and still listed")
    func mentionToUnknownLIDIsUnchanged() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = SystemWhatsAppStore(path: fixture.databasePath)

        let page = try await store.messages(matching: MessageQuery(chatID: 3))
        let message = try #require(page.rows.first { $0.id == 51 })

        #expect(message.text == "ping @12345678901234 anyone?")
        // Hiding an unresolved mention would be a worse answer than an unnamed one.
        #expect(message.mentions.count == 1)
        #expect(message.mentions.first?.name == nil)
    }

    // MARK: Group events

    @Test("A group event's actor resolves through the profile table; an unnamed subject stays a JID")
    func groupEventResolvesActorNotAlwaysSubject() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = SystemWhatsAppStore(path: fixture.databasePath)

        let page = try await store.messages(matching: MessageQuery(chatID: 3))
        let message = try #require(page.rows.first { $0.id == 60 })

        guard case .groupEvent(let event) = message.body else {
            Issue.record("message 60 is not a group event")
            return
        }
        #expect(event.code == 2)
        #expect(event.actor.displayName == "Grace Hopper")
        // 444@lid has no ZWAPROFILEPUSHNAME row — only ZWAGROUPMEMBER, which a group
        // event's subject deliberately does not consult — so it surfaces as the bare JID
        // rather than silently becoming "unknown".
        #expect(event.subject?.displayName == "444@lid")
        // A group event has no text of its own; its ZTEXT is the subject's address, and
        // showing that as a message body would be a lie.
        #expect(message.text == nil)
    }

    @Test("A group event's actor with no profile name renders as a phone number")
    func groupEventActorRendersAsPhoneNumber() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = SystemWhatsAppStore(path: fixture.databasePath)

        let page = try await store.messages(matching: MessageQuery(chatID: 3))
        let message = try #require(page.rows.first { $0.id == 61 })

        guard case .groupEvent(let event) = message.body else {
            Issue.record("message 61 is not a group event")
            return
        }
        #expect(event.code == 3)
        #expect(event.actor.displayName == "+34600111222")
        #expect(event.actor.kind == .phone)
        #expect(event.subject == nil)
    }

    /// The measured library has 145 type-6/10 rows whose `ZTEXT` carries no subject, and
    /// not one of them has a `ZWAGROUPMEMBERSCHANGE` row within seconds of it. A
    /// subject-less group event therefore stays subject-less, and this test pins that
    /// rather than letting a future edit reintroduce a correlation that cannot fire.
    @Test("A group event with no subject in ZTEXT reports none, and invents nothing")
    func subjectlessGroupEventStaysSubjectless() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = SystemWhatsAppStore(path: fixture.databasePath)

        let page = try await store.messages(matching: MessageQuery(chatID: 3, limit: 100))
        let message = try #require(page.rows.first { $0.id == 80 })
        guard case .groupEvent(let event) = message.body else {
            Issue.record("message 80 is not a group event")
            return
        }
        #expect(event.actor.displayName == "Grace Hopper")
        #expect(event.subject == nil)
    }

    @Test("An ordinary message is never classified as a group event")
    func ordinaryMessageHasNoGroupEvent() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = SystemWhatsAppStore(path: fixture.databasePath)

        let page = try await store.messages(matching: MessageQuery(chatID: 1, limit: 100))
        for row in page.rows {
            if case .groupEvent = row.body {
                Issue.record("message \(row.id) is not a group event but was read as one")
            }
        }
    }

    // MARK: Deleted messages

    @Test("A deleted message keeps its sender and date and offers nothing else")
    func deletedMessageOffersNothing() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = SystemWhatsAppStore(path: fixture.databasePath)

        let message = try #require(try await store.message(id: 91))
        #expect(message.body == .deletedForEveryone)
        // ZTEXT on a type-14 row holds a JID on the few rows that have anything at all.
        // Surfaced as text it would read as the deleted message's content, which is the one
        // thing that is definitely gone.
        #expect(message.text == nil)
        #expect(message.sender?.displayName == "Ada Lovelace")
    }

    // MARK: Locations and contact cards

    @Test("A shared location reports its coordinates, in chat_get as well as in media_list")
    func locationReportsCoordinates() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = SystemWhatsAppStore(path: fixture.databasePath)

        let entry = try #require(
            try await store.media(matching: MessageQuery(kinds: [.location])).rows.first)
        guard case .location(let coordinates) = entry.body else {
            Issue.record("the location row is not a location")
            return
        }
        #expect(abs(coordinates.latitude - 43.318334) < 0.000001)
        #expect(abs(coordinates.longitude - (-1.981231)) < 0.000001)

        // The same position has to reach chat_get, or a location message reads as a bare
        // "[location]" and the caller has to run a second tool to learn anything.
        let page = try await store.messages(matching: MessageQuery(chatID: 1, limit: 100))
        let row = try #require(page.rows.first { $0.id == 70 })
        #expect(row.body == entry.body)
    }

    /// The bug this pins down is not "a slightly wrong number": a photo whose stored pixel
    /// height is 3024 would be reported as a place at latitude 3024, and nothing in the
    /// output would let a reader tell that from a real location.
    @Test("A photo's pixel dimensions are never reported as coordinates")
    func pixelDimensionsAreNotAPosition() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = SystemWhatsAppStore(path: fixture.databasePath)

        let page = try await store.messages(matching: MessageQuery(limit: 100))
        for row in page.rows where row.id != 70 {
            if case .location = row.body {
                Issue.record("message \(row.id) invented a position")
            }
        }
    }

    @Test("A shared contact reports its name and vCard; the base64 key elsewhere never does")
    func contactCardOnlyOnContactRows() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = SystemWhatsAppStore(path: fixture.databasePath)

        let entry = try #require(
            try await store.media(matching: MessageQuery(kinds: [.contactCard])).rows.first)
        guard case .contactCard(let card) = entry.body else {
            Issue.record("the contact row is not a contact card")
            return
        }
        #expect(card.name == "Invented Contact")
        #expect(card.vcard?.hasPrefix("BEGIN:VCARD") == true)

        // The same two columns, every other kind: a base64 key on the photo, the sticker,
        // the document and both audio rows. Not one of them may reach a caller as a person.
        let page = try await store.messages(matching: MessageQuery(limit: 100))
        for row in page.rows where row.id != 71 {
            if case .contactCard = row.body {
                Issue.record("message \(row.id) shows a key as a shared contact")
            }
        }
    }

    // MARK: Delivery

    @Test("A delivery code travels as the number WhatsApp stored, error included")
    func deliveryCodeIsCarriedRaw() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = SystemWhatsAppStore(path: fixture.databasePath)

        let ordinary = try #require(try await store.message(id: 10))
        #expect(ordinary.delivery.rawCode == 6)
        // Zero means no error, so reporting it as one would put a failure on 26,806 healthy
        // rows.
        #expect(ordinary.delivery.errorCode == nil)

        let failed = try #require(try await store.message(id: 120))
        #expect(failed.delivery.rawCode == 8)
        #expect(failed.delivery.errorCode == 813_362_195)
        #expect(failed.sentDate != nil)
    }

    // MARK: Groups

    @Test("group reads creation, subject-change and picture fields, resolved through JIDDisplay")
    func groupReadsMetadata() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = SystemWhatsAppStore(path: fixture.databasePath)

        let group = try #require(try await store.group(chatID: 3))

        #expect(group.creator?.displayName == "Grace Hopper")
        #expect(
            abs((group.creationDate?.timeIntervalSinceReferenceDate ?? 0) - (reference - 999_999))
                < 1)
        #expect(group.subjectChangedBy?.displayName == "444@lid")
        let subjectDate = try #require(group.subjectChangedDate)
        #expect(abs(subjectDate.timeIntervalSinceReferenceDate - (reference - 500)) < 1)
        #expect(group.pictureID == "pic-abc")
    }

    @Test("group lists every ZWAGROUPMEMBER row for the chat, admin and inactive flags intact")
    func groupListsMembers() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = SystemWhatsAppStore(path: fixture.databasePath)

        let group = try #require(try await store.group(chatID: 3))
        #expect(group.members.count == 3)

        let admin = try #require(group.members.first { $0.identity.jid == "333@lid" })
        #expect(admin.identity.displayName == "Grace Hopper")
        #expect(admin.isAdmin == true)
        #expect(admin.isActive == true)

        // No push name and no member-row name: identified by address, not dropped.
        let unnamed = try #require(group.members.first { $0.identity.jid == "666@lid" })
        #expect(unnamed.identity.displayName == "666@lid")
        #expect(unnamed.isAdmin == false)
        #expect(unnamed.isActive == false)
    }

    /// `ZFIRSTNAME` is not a first name — 72 of 80 populated rows on the measured library
    /// are exactly five characters and none contains a space. The fixture stores that shape
    /// so a future edit that starts reading it shows up as a member called `CNXy9`.
    @Test("ZWAGROUPMEMBER.ZFIRSTNAME never reaches a member's name")
    func firstNameKeyNeverSurfaces() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = SystemWhatsAppStore(path: fixture.databasePath)

        let group = try #require(try await store.group(chatID: 3))
        for member in group.members {
            #expect(member.identity.displayName != "CNXy9")
            #expect(member.identity.displayName != "Bk2Lp")
        }
    }

    @Test("group returns nil for a chat with no ZWAGROUPINFO row")
    func groupNilForOrdinaryChat() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = SystemWhatsAppStore(path: fixture.databasePath)

        #expect(try await store.group(chatID: 1) == nil)
    }

    // MARK: One row shape

    /// `chat_get`, `whatsapp_search` and `media_list` render through one function, and this
    /// is what proves they read the same row. Three renderers meant a photo could be
    /// described one way in a conversation and another way in an attachment list.
    @Test("The same message reads identically whether it came from a chat or a search")
    func oneMessageRendersIdenticallyEverywhere() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = SystemWhatsAppStore(path: fixture.databasePath)

        let fromChat = try #require(
            try await store.messages(matching: MessageQuery(chatID: 1, limit: 100)).rows
                .first { $0.id == 40 })
        let fromSearch = try #require(
            try await store.messages(matching: MessageQuery(limit: 100)).rows
                .first { $0.id == 40 })
        let fromMedia = try #require(
            try await store.media(matching: MessageQuery(kinds: [.photo])).rows
                .first { $0.id == 40 })

        #expect(fromChat == fromSearch)
        #expect(fromChat == fromMedia)
    }

    @Test("An unknown message id has no row rather than an invented one")
    func unknownMessageIsNil() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = SystemWhatsAppStore(path: fixture.databasePath)

        #expect(try await store.message(id: 99999) == nil)
    }
}
