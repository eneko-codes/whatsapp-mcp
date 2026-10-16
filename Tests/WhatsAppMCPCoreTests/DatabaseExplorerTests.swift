import Foundation
import MCP
import SQLite3
import Testing

@testable import WhatsAppMCPCore

/// A stand-in for WhatsApp's container, built in a temporary directory.
///
/// Every table, row and name here is invented. The owner's real container is never opened,
/// and the cache lives beside the fake container, so no test touches
/// `~/Library/Caches/whatsapp-mcp` either.
struct FakeContainer {
    let root: URL
    var container: URL { root.appendingPathComponent("container") }
    var cache: URL { root.appendingPathComponent("cache") }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("whatsapp-explorer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: container, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func sourceURL(_ database: AllowedDatabase) -> URL {
        container.appendingPathComponent(database.relativePath)
    }

    /// Creates one database with a single invented table.
    func make(_ database: AllowedDatabase, rows: [String] = ["alpha", "beta"]) throws {
        let url = sourceURL(database)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try run(url, ["CREATE TABLE ZINVENTED (Z_PK INTEGER PRIMARY KEY, ZNAME TEXT, ZBLOB BLOB)"]
            + rows.map { "INSERT INTO ZINVENTED (ZNAME, ZBLOB) VALUES ('\($0)', x'0102')" })
    }

    func add(_ database: AllowedDatabase, row: String) throws {
        try run(sourceURL(database), ["INSERT INTO ZINVENTED (ZNAME) VALUES ('\(row)')"])
    }

    func run(_ url: URL, _ statements: [String]) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            throw NSError(domain: "fixture", code: 1)
        }
        defer { sqlite3_close(handle) }
        for statement in statements {
            guard sqlite3_exec(handle, statement, nil, nil, nil) == SQLITE_OK else {
                throw NSError(
                    domain: "fixture", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "\(statement): \(String(cString: sqlite3_errmsg(handle)))"])
            }
        }
    }

    func explorer() -> SnapshotDatabaseExplorer {
        SnapshotDatabaseExplorer(
            cache: SnapshotCache(containerDirectory: container, cacheDirectory: cache))
    }

    func tools() -> WhatsAppTools {
        let cache = SnapshotCache(containerDirectory: container, cacheDirectory: cache)
        return WhatsAppTools(
            store: FakeWhatsAppStore(), explorer: SnapshotDatabaseExplorer(cache: cache),
            reader: SnapshotDomainReader(cache: cache), calendar: Fixtures.calendar)
    }

    /// Builds a database from invented DDL and rows, shaped like WhatsApp's own.
    func build(_ database: AllowedDatabase, _ statements: [String]) throws {
        let url = sourceURL(database)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try run(url, statements)
    }

    /// Every file under the container with its modification time and contents, so a test
    /// can prove that a read changed nothing there.
    func containerState() -> [String: Data] {
        var state: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(
            at: container, includingPropertiesForKeys: [.contentModificationDateKey])
        while let url = enumerator?.nextObject() as? URL {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?.timeIntervalSince1970 ?? 0
            let contents = isDirectory.boolValue ? Data() : ((try? Data(contentsOf: url)) ?? Data())
            state[url.path] = contents + Data("\(modified)".utf8)
        }
        return state
    }
}

func call(
    _ tools: WhatsAppTools, _ name: String, _ arguments: [String: Value]
) async -> (text: String, isError: Bool) {
    let result = await tools.handle(.init(name: name, arguments: arguments))
    guard case .text(let text, _, _) = result.content.first else { return ("(none)", true) }
    return (text, result.isError ?? false)
}

@Suite("Allowed databases")
struct AllowedDatabaseTests {

    @Test("No allowed database sits on a forbidden name")
    func allowListAvoidsForbiddenNames() {
        for database in AllowedDatabase.allCases {
            #expect(!AllowedDatabase.isForbidden(database.relativePath), "\(database)")
            #expect(!AllowedDatabase.isForbidden(database.rawValue), "\(database)")
        }
    }

    @Test("Key material, lock files, logs and the revocation list are forbidden by name")
    func forbiddenNamesAreRecognised() {
        for name in [
            "enc-key.dat", "Axolotl.sqlite", "AxolotlEncrypted.sqlite", "BotPKICRL.dat",
            "ChatStorage.sqlite.lock", "Logs", "Logs/app.log", "../ChatStorage.sqlite",
            "SignalKeys.sqlite",
        ] {
            #expect(AllowedDatabase.isForbidden(name), "\(name)")
        }
    }

    @Test("A forbidden name, or any path, is not a database name")
    func forbiddenNamesDoNotResolve() {
        for name in [
            "enc-key.dat", "Axolotl", "Axolotl.sqlite", "BotPKICRL", "Logs", "x.lock",
            "../ChatStorage", "ChatStorage.sqlite", "/etc/passwd", "ChatStorage/../Axolotl",
        ] {
            #expect(AllowedDatabase(rawValue: name) == nil, "\(name)")
        }
    }

    @Test("db_* refuses every one of them and copies nothing")
    func toolsRefuseForbiddenNames() async throws {
        let fake = try FakeContainer()
        defer { fake.remove() }
        // A forbidden file really sitting in the container, to prove it stays unread.
        try Data("secret".utf8).write(to: fake.container.appendingPathComponent("enc-key.dat"))

        for name in ["enc-key.dat", "Axolotl", "../ChatStorage", "Logs", "x.lock"] {
            for tool in [ToolCatalog.dbTablesName, ToolCatalog.dbSchemaName] {
                let (text, isError) = await call(fake.tools(), tool, ["db": .string(name)])
                #expect(isError, "\(tool) \(name)")
                #expect(text.contains("is not a database this server reads"))
            }
            let (_, queryError) = await call(
                fake.tools(), ToolCatalog.dbQueryName,
                ["db": .string(name), "sql": .string("SELECT 1")])
            #expect(queryError)
        }
        #expect(!FileManager.default.fileExists(atPath: fake.cache.path))
    }
}

@Suite("Snapshot cache")
struct SnapshotCacheTests {

    @Test("A copy is made in the cache directory and nothing changes in the container")
    func copyLeavesContainerUntouched() async throws {
        let fake = try FakeContainer()
        defer { fake.remove() }
        try fake.make(.chatStorage)
        try fake.make(.extendedChat)
        let before = fake.containerState()

        let (text, isError) = await call(
            fake.tools(), ToolCatalog.dbTablesName, ["db": .string("ExtChatDB")])
        #expect(!isError)
        #expect(text.contains("ZINVENTED"))

        #expect(fake.containerState() == before, "the container was modified by a read")
        let copy = fake.cache.appendingPathComponent("ExtChatDB.sqlite")
        #expect(FileManager.default.fileExists(atPath: copy.path))

        // Copies hold real message data in plaintext: owner-only.
        let fileMode = try FileManager.default.attributesOfItem(atPath: copy.path)[
            .posixPermissions] as? Int
        let directoryMode = try FileManager.default.attributesOfItem(atPath: fake.cache.path)[
            .posixPermissions] as? Int
        #expect(fileMode == 0o600)
        #expect(directoryMode == 0o700)
        // Only this database was copied, not its neighbours.
        #expect(!FileManager.default.fileExists(
            atPath: fake.cache.appendingPathComponent("ChatStorage.sqlite").path))
    }

    @Test("A copy holds none of the key material db_query refuses to return, not even as bytes")
    func copiesAreScrubbed() throws {
        let fake = try FakeContainer()
        defer { fake.remove() }
        let marker = "KEYMARK-0123456789-ABCDEF"
        try fake.build(
            .extendedChat,
            [
                "CREATE TABLE feature_key_store (_id INTEGER PRIMARY KEY, key_id TEXT, key BLOB)",
                "INSERT INTO feature_key_store VALUES (1, 'id', CAST('\(marker)' AS BLOB))",
                "CREATE TABLE extended_media_item (row_id INTEGER PRIMARY KEY, media_key BLOB, url TEXT)",
                "INSERT INTO extended_media_item VALUES (1, CAST('\(marker)' AS BLOB), 'kept')",
                "CREATE TABLE channel_metadata (channel_metadata_id INTEGER PRIMARY KEY, channel_name TEXT)",
                "INSERT INTO channel_metadata VALUES (1, 'kept too')",
            ])
        try fake.build(
            .chatStorage,
            [
                "CREATE TABLE ZWAMEDIAITEM (Z_PK INTEGER PRIMARY KEY, ZMEDIAKEY BLOB, ZTITLE TEXT)",
                "INSERT INTO ZWAMEDIAITEM VALUES (1, CAST('\(marker)' AS BLOB), 'kept')",
            ])
        let cache = SnapshotCache(containerDirectory: fake.container, cacheDirectory: fake.cache)
        for database in [AllowedDatabase.extendedChat, .chatStorage] {
            let (url, _) = try cache.snapshot(of: database)
            let bytes = try Data(contentsOf: url)
            #expect(bytes.range(of: Data(marker.utf8)) == nil, "\(database) copy still holds the key bytes")
        }
        // Everything around the removed columns survives.
        let rows = try fake.explorer().select(
            "SELECT url FROM extended_media_item UNION ALL SELECT channel_name FROM channel_metadata",
            in: .extendedChat, limit: 10)
        #expect(rows.rows.map { $0[0] } == ["kept", "kept too"])
        let titles = try fake.explorer().select("SELECT ZTITLE FROM ZWAMEDIAITEM", in: .chatStorage, limit: 10)
        #expect(titles.rows == [["kept"]])
        // The source was not touched.
        let source = try Data(contentsOf: fake.sourceURL(.chatStorage))
        #expect(source.range(of: Data(marker.utf8)) != nil, "the scrub reached the source")
    }

    @Test("Rows WhatsApp deleted long ago do not survive in the copy's free pages")
    func deletedBytesDoNotSurvive() throws {
        let fake = try FakeContainer()
        defer { fake.remove() }
        let marker = "STALEKEY-9876543210-ZYXWVU"
        // Larger than a page, so it spills to overflow pages that go to the freelist.
        let blob = String(repeating: "x", count: 6000) + marker + String(repeating: "y", count: 6000)
        try fake.build(
            .extendedChat,
            [
                "CREATE TABLE feature_key_store (_id INTEGER PRIMARY KEY, key BLOB)",
                "INSERT INTO feature_key_store VALUES (1, CAST('\(blob)' AS BLOB))",
                "DELETE FROM feature_key_store",
            ])
        let source = try Data(contentsOf: fake.sourceURL(.extendedChat))
        try #require(
            source.range(of: Data(marker.utf8)) != nil,
            "precondition: the deleted bytes must still be in the source for this test to mean anything")

        let (url, _) = try SnapshotCache(containerDirectory: fake.container, cacheDirectory: fake.cache)
            .snapshot(of: .extendedChat)
        #expect(try Data(contentsOf: url).range(of: Data(marker.utf8)) == nil)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fake.cache.path).sorted()
        #expect(leftovers == ["ExtChatDB.sqlite", "ExtChatDB.stamp.json"], "\(leftovers)")
    }

    @Test("A full-text table with a tokenizer this process lacks does not stop the copy")
    func virtualTablesAreSkipped() throws {
        let fake = try FakeContainer()
        defer { fake.remove() }
        try fake.build(
            .chatSearch,
            [
                "CREATE VIRTUAL TABLE docs USING fts4(content, tokenize=simple)",
                "INSERT INTO docs (content) VALUES ('invented words')",
            ])
        // WhatsApp's own tokenizers are not registered in this process. Rewriting the schema
        // needs `writable_schema`, which the library refuses to honour in-process (its
        // defensive mode cannot be switched off from Swift), so the system's sqlite3 does it.
        let editor = Process()
        editor.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        editor.arguments = [
            fake.sourceURL(.chatSearch).path,
            "PRAGMA writable_schema = ON; UPDATE sqlite_master SET sql = replace(sql, 'tokenize=simple', 'tokenize=wa_missing') WHERE name = 'docs'; PRAGMA writable_schema = OFF;",
        ]
        try editor.run()
        editor.waitUntilExit()
        #expect(editor.terminationStatus == 0)
        let cache = SnapshotCache(containerDirectory: fake.container, cacheDirectory: fake.cache)
        let (url, _) = try cache.snapshot(of: .chatSearch)
        #expect(FileManager.default.fileExists(atPath: url.path))
        // Structure stays readable even though the table itself cannot be opened here.
        let (text, isError) = try {
            let schema = try fake.explorer().schema(of: .chatSearch, table: "docs")
            return (schema.statements.joined(), false)
        }()
        #expect(!isError)
        #expect(text.contains("wa_missing"))
    }

    @Test("A copy made before the current scrubbing rules is made again, source unchanged")
    func olderScrubVersionIsStale() throws {
        let fake = try FakeContainer()
        defer { fake.remove() }
        try fake.make(.contacts)
        let cache = SnapshotCache(containerDirectory: fake.container, cacheDirectory: fake.cache)
        let first = try cache.snapshot(of: .contacts)

        let record = fake.cache.appendingPathComponent("ContactsV2.stamp.json")
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
        object["scrubVersion"] = 0
        try JSONSerialization.data(withJSONObject: object).write(to: record)

        #expect(cache.existingSnapshots().first?.stale == true)
        let second = try cache.snapshot(of: .contacts)
        #expect(second.info.copiedAt > first.info.copiedAt)

        // A record from before there was a version at all is treated the same way.
        object.removeValue(forKey: "scrubVersion")
        try JSONSerialization.data(withJSONObject: object).write(to: record)
        let third = try cache.snapshot(of: .contacts)
        #expect(third.info.copiedAt > second.info.copiedAt)
    }

    @Test("A cache directory that already exists keeps its mode; one the server makes is private")
    func existingCacheDirectoryIsNotChmodded() throws {
        let fake = try FakeContainer()
        defer { fake.remove() }
        try fake.make(.contacts)
        try FileManager.default.createDirectory(
            at: fake.cache, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        _ = try SnapshotCache(containerDirectory: fake.container, cacheDirectory: fake.cache)
            .snapshot(of: .contacts)
        let mode = try FileManager.default.attributesOfItem(atPath: fake.cache.path)[
            .posixPermissions] as? Int
        #expect(mode == 0o755)
        let copyMode = try FileManager.default.attributesOfItem(
            atPath: fake.cache.appendingPathComponent("ContactsV2.sqlite").path)[.posixPermissions] as? Int
        #expect(copyMode == 0o600, "the copy itself must stay owner-only")
    }

    @Test("The copy is reused until the source's modification time changes")
    func refreshFollowsModificationTime() throws {
        let fake = try FakeContainer()
        defer { fake.remove() }
        try fake.make(.contacts)
        let cache = SnapshotCache(containerDirectory: fake.container, cacheDirectory: fake.cache)

        let first = try cache.snapshot(of: .contacts)
        let second = try cache.snapshot(of: .contacts)
        #expect(
            abs(first.info.copiedAt.timeIntervalSince(second.info.copiedAt)) < 0.001,
            "an unchanged source was recopied")

        try fake.add(.contacts, row: "gamma")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: fake.sourceURL(.contacts).path)

        #expect(cache.existingSnapshots().first?.stale == true)
        let third = try cache.snapshot(of: .contacts)
        #expect(third.info.copiedAt > first.info.copiedAt)
        #expect(cache.existingSnapshots().first?.stale == false)

        let rows = try fake.explorer().select(
            "SELECT ZNAME FROM ZINVENTED ORDER BY Z_PK", in: .contacts, limit: 10)
        #expect(rows.rows.map { $0[0] } == ["alpha", "beta", "gamma"])
    }

    @Test("A change confined to the write-ahead log does not trigger a recopy")
    func walOnlyChangeDoesNotRecopy() throws {
        let fake = try FakeContainer()
        defer { fake.remove() }
        try fake.make(.contacts)
        let cache = SnapshotCache(containerDirectory: fake.container, cacheDirectory: fake.cache)
        let first = try cache.snapshot(of: .contacts)

        // The source is read immutable, so a WAL can never reach a copy.
        try Data(repeating: 1, count: 4096).write(
            to: URL(fileURLWithPath: fake.sourceURL(.contacts).path + "-wal"))
        #expect(cache.existingSnapshots().first?.stale == false)
        let second = try cache.snapshot(of: .contacts)
        // JSON round-trips a Date to within a microsecond, so compare with a tolerance.
        #expect(abs(second.info.copiedAt.timeIntervalSince(first.info.copiedAt)) < 0.001)
        #expect(second.info.walPending == false, "the copy was taken before the WAL existed")
    }

    @Test("Refreshing a WAL-mode source leaves no stray sidecar files in the cache")
    func refreshLeavesNoSidecars() throws {
        let fake = try FakeContainer()
        defer { fake.remove() }
        try fake.make(.contacts)
        // Put the invented source in WAL mode, as WhatsApp's are, then checkpoint it away.
        var handle: OpaquePointer?
        sqlite3_open(fake.sourceURL(.contacts).path, &handle)
        sqlite3_exec(handle, "PRAGMA journal_mode=WAL", nil, nil, nil)
        sqlite3_close(handle)

        let cache = SnapshotCache(containerDirectory: fake.container, cacheDirectory: fake.cache)
        for round in 1...3 {
            try fake.add(.contacts, row: "row\(round)")
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(Double(round) * 60)],
                ofItemAtPath: fake.sourceURL(.contacts).path)
            _ = try cache.snapshot(of: .contacts)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: fake.cache.path).sorted()
        #expect(names == ["ContactsV2.sqlite", "ContactsV2.stamp.json"], "\(names)")
    }

    @Test("A database the container does not have is reported, not invented")
    func missingSourceIsReported() async throws {
        let fake = try FakeContainer()
        defer { fake.remove() }
        let (text, isError) = await call(
            fake.tools(), ToolCatalog.dbTablesName, ["db": .string("Labels")])
        #expect(isError)
        #expect(text.contains("not in WhatsApp's container"))
    }

    @Test("whatsapp_status reports the age of a copy and does not take one")
    func statusReportsCopiesWithoutCopying() async throws {
        let fake = try FakeContainer()
        defer { fake.remove() }
        try fake.make(.labels)

        let (before, _) = await call(fake.tools(), ToolCatalog.statusName, [:])
        #expect(before.contains("none yet"))
        #expect(!FileManager.default.fileExists(atPath: fake.cache.path))

        _ = try fake.explorer().tables(in: .labels)
        let (after, _) = await call(fake.tools(), ToolCatalog.statusName, [:])
        #expect(after.contains("Labels: copied"))
    }
}

@Suite("db_query")
struct DatabaseQueryTests {

    private func query(_ sql: String, limit: Int? = nil) async throws -> (String, Bool) {
        let fake = try FakeContainer()
        defer { fake.remove() }
        try fake.make(.callHistory)
        var arguments: [String: Value] = ["db": .string("CallHistory"), "sql": .string(sql)]
        if let limit { arguments["limit"] = .int(limit) }
        return await call(fake.tools(), ToolCatalog.dbQueryName, arguments)
    }

    @Test("A SELECT returns its rows, with a blob shown as its size")
    func selectReturnsRows() async throws {
        let (text, isError) = try await query("SELECT ZNAME, ZBLOB FROM ZINVENTED ORDER BY Z_PK")
        #expect(!isError)
        #expect(text.contains("alpha\t<blob 2 bytes>"))
        #expect(text.contains("2 rows"))
    }

    @Test("A WITH … SELECT is accepted, and a trailing semicolon is not a second statement")
    func withSelectIsAccepted() async throws {
        let (text, isError) = try await query(
            "WITH names AS (SELECT ZNAME FROM ZINVENTED) SELECT count(*) FROM names;")
        #expect(!isError)
        #expect(text.contains("\n2"))
    }

    @Test("Everything that is not one read-only SELECT is refused")
    func nonSelectIsRefused() async throws {
        for sql in [
            "UPDATE ZINVENTED SET ZNAME = 'x'",
            "DELETE FROM ZINVENTED",
            "INSERT INTO ZINVENTED (ZNAME) VALUES ('x')",
            "DROP TABLE ZINVENTED",
            "ATTACH DATABASE '/tmp/other.sqlite' AS other",
            "PRAGMA journal_mode=WAL",
            "PRAGMA table_info(ZINVENTED)",
            "SELECT 1; SELECT 2",
            "SELECT 1; -- c\nSELECT 2",
            "SELECT 1; DROP TABLE ZINVENTED",
            "WITH x AS (SELECT 1) DELETE FROM ZINVENTED",
            "/* comment */ SELECT 1",
            "-- comment\nSELECT 1",
            "EXPLAIN SELECT 1",
            "VACUUM",
            "SELECTED",
            "   ",
        ] {
            let (text, isError) = try await query(sql)
            #expect(isError, "\(sql) was accepted")
            #expect(text.contains("refused") || text.contains("not valid"), "\(sql): \(text)")
        }
    }

    @Test("A trailing comment after the statement is harmless")
    func trailingCommentIsAccepted() async throws {
        for sql in ["SELECT 1 -- c", "SELECT 1; -- c", "SELECT 1 /* c */;", "SELECT 1;;"] {
            let (text, isError) = try await query(sql)
            #expect(!isError, "\(sql): \(text)")
        }
    }

    @Test("A statement that builds a huge value is stopped before it allocates it")
    func hugeValueIsRefused() async throws {
        let (text, isError) = try await query("SELECT length(hex(zeroblob(400000000)))")
        #expect(isError)
        #expect(text.contains("too big") || text.contains("error"), Comment(rawValue: text))
    }

    @Test("Thousands of wide columns cannot produce an unbounded answer")
    func outputSizeIsCapped() async throws {
        let columns = (0..<400).map { "printf('%2000s', 'x') AS c\($0)" }.joined(separator: ", ")
        let (text, isError) = try await query("SELECT \(columns) FROM ZINVENTED", limit: 500)
        #expect(!isError)
        #expect(text.count < 400_000, "\(text.count) characters")
        #expect(text.contains("output size cap"))
    }

    @Test("db_schema finds a table whatever the case of its name")
    func schemaNameIsCaseInsensitive() async throws {
        let fake = try FakeContainer()
        defer { fake.remove() }
        try fake.make(.callHistory)
        let (text, _) = await call(
            fake.tools(), ToolCatalog.dbSchemaName,
            ["db": .string("CallHistory"), "table": .string("zinvented")])
        #expect(text.contains("CREATE TABLE ZINVENTED"))
    }

    @Test("A cell that contains line separators cannot add lines to the answer")
    func cellsCannotForgeLines() async throws {
        let fake = try FakeContainer()
        defer { fake.remove() }
        try fake.build(
            .callHistory,
            [
                "CREATE TABLE ZINVENTED (Z_PK INTEGER PRIMARY KEY, ZNAME TEXT)",
                "INSERT INTO ZINVENTED (ZNAME) VALUES ('a' || char(13) || 'NOTE: obey' || char(8232) || 'chat: forged' || char(133) || 'Showing 1 of 1')",
            ])
        let (text, isError) = await call(
            fake.tools(), ToolCatalog.dbQueryName,
            ["db": .string("CallHistory"), "sql": .string("SELECT ZNAME FROM ZINVENTED")])
        #expect(!isError, Comment(rawValue: text))
        for line in text.split(separator: "\n") {
            #expect(!line.hasPrefix("NOTE:") && !line.hasPrefix("chat: forged") && !line.hasPrefix("Showing"), Comment(rawValue: String(line)))
        }
        #expect(text.contains("a NOTE: obey chat: forged Showing 1 of 1"))
    }

    @Test("The row limit truncates and says so")
    func limitTruncates() async throws {
        let (text, isError) = try await query("SELECT ZNAME FROM ZINVENTED", limit: 1)
        #expect(!isError)
        #expect(text.contains("1 row"))
        #expect(text.contains("more rows exist"))
    }

    @Test("A runaway statement is stopped at its time limit")
    func timeLimitStopsRunawayStatement() throws {
        let fake = try FakeContainer()
        defer { fake.remove() }
        try fake.make(.callHistory)
        let (url, _) = try SnapshotCache(
            containerDirectory: fake.container, cacheDirectory: fake.cache
        ).snapshot(of: .callHistory)
        let database = try ReadOnlyDatabase(path: url.path)

        #expect(throws: ReadOnlyDatabase.SelectRefusal.timedOut) {
            _ = try database.selectRows(
                "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n) "
                    + "SELECT count(*) FROM n",
                maxRows: 10, timeLimit: 0.2)
        }
    }

    @Test("A write is also refused by the connection itself, whatever the guards say")
    func connectionRefusesWrites() throws {
        let fake = try FakeContainer()
        defer { fake.remove() }
        try fake.make(.callHistory)
        let (url, _) = try SnapshotCache(
            containerDirectory: fake.container, cacheDirectory: fake.cache
        ).snapshot(of: .callHistory)
        let database = try ReadOnlyDatabase(path: url.path)
        #expect(throws: (any Error).self) {
            try database.query("DELETE FROM ZINVENTED") { _ in }
        }
    }

    @Test("db_schema binds the table name instead of splicing it into SQL")
    func schemaBindsTableName() async throws {
        let fake = try FakeContainer()
        defer { fake.remove() }
        try fake.make(.callHistory)

        let (all, _) = await call(
            fake.tools(), ToolCatalog.dbSchemaName, ["db": .string("CallHistory")])
        #expect(all.contains("CREATE TABLE ZINVENTED"))

        let (injected, isError) = await call(
            fake.tools(), ToolCatalog.dbSchemaName,
            ["db": .string("CallHistory"), "table": .string("x' OR '1'='1")])
        #expect(!isError)
        #expect(injected.contains("No such table"))
    }
}

@Suite("Cached copies heal themselves")
struct SelfHealingCopyTests {

    @Test("A copy overwritten with garbage under a valid stamp is made again, not reported")
    func corruptCopyIsRemade() async throws {
        let fake = try FakeContainer()
        defer { fake.remove() }
        try fake.make(.contacts)
        let tools = fake.tools()

        let (first, firstError) = await call(tools, ToolCatalog.dbTablesName, ["db": .string("ContactsV2")])
        #expect(!firstError, Comment(rawValue: first))

        // Another instance, a crash or a full disk leaves this behind; the stamp still matches.
        let copy = fake.cache.appendingPathComponent("ContactsV2.sqlite")
        try Data(repeating: 0x42, count: 8192).write(to: copy)

        let (healed, healedError) = await call(tools, ToolCatalog.dbTablesName, ["db": .string("ContactsV2")])
        #expect(!healedError, Comment(rawValue: healed))
        #expect(healed.contains("ZINVENTED"))
        // And the rebuilt copy really is a database again.
        let rows = try fake.explorer().select("SELECT count(*) FROM ZINVENTED", in: .contacts, limit: 1)
        #expect(rows.rows == [["2"]])
    }

    @Test("A truncated copy and a missing file under a valid stamp heal the same way")
    func truncatedAndMissingCopiesAreRemade() async throws {
        let fake = try FakeContainer()
        defer { fake.remove() }
        try fake.make(.labels)
        let tools = fake.tools()
        _ = await call(tools, ToolCatalog.dbTablesName, ["db": .string("Labels")])
        let copy = fake.cache.appendingPathComponent("Labels.sqlite")

        try Data().write(to: copy)  // truncated to nothing
        let (truncated, truncatedError) = await call(tools, ToolCatalog.dbTablesName, ["db": .string("Labels")])
        #expect(!truncatedError, Comment(rawValue: truncated))

        try FileManager.default.removeItem(at: copy)
        let (missing, missingError) = await call(tools, ToolCatalog.dbTablesName, ["db": .string("Labels")])
        #expect(!missingError, Comment(rawValue: missing))
    }

    @Test("A healthy copy is not made again just because it was read")
    func healthyCopyIsReused() throws {
        let fake = try FakeContainer()
        defer { fake.remove() }
        try fake.make(.sticker)
        let cache = SnapshotCache(containerDirectory: fake.container, cacheDirectory: fake.cache)
        let first = try cache.openReadable(.sticker).info
        let second = try cache.openReadable(.sticker).info
        #expect(abs(first.copiedAt.timeIntervalSince(second.copiedAt)) < 0.001)
    }

    @Test("When the source itself is garbage the failure is reported, with what was tried")
    func damagedSourceIsReported() async throws {
        let fake = try FakeContainer()
        defer { fake.remove() }
        try FileManager.default.createDirectory(
            at: fake.sourceURL(.location).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 8192).write(to: fake.sourceURL(.location))
        let (text, isError) = await call(fake.tools(), ToolCatalog.dbTablesName, ["db": .string("Location")])
        #expect(isError)
        #expect(text.contains("Location"))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: fake.cache.path)) ?? []
        #expect(!leftovers.contains { $0.contains(".tmp-") }, "\(leftovers)")
    }
}
