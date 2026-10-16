import Foundation
import MCP
import SQLite3
import Testing

@testable import WhatsAppMCPCore

/// macOS answers a missing privacy grant with `EPERM` on `open(2)`; a file with no read
/// permission answers `EACCES`. Both are "the file is there and this program may not open
/// it", which is what these tests build, with invented files in a temporary directory.
@Suite("Access denied is not 'not found'")
struct AccessDeniedTests {

    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whatsapp-denied-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func deniedFile(in directory: URL, named name: String = "ChatStorage.sqlite") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("not a database".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        return url
    }

    private func call(_ tools: WhatsAppTools, _ name: String, _ arguments: [String: Value] = [:]) async
        -> (text: String, isError: Bool)
    {
        let result = await tools.handle(.init(name: name, arguments: arguments))
        guard case .text(let text, _, _) = result.content.first else { return ("", true) }
        return (text, result.isError ?? false)
    }

    @Test("The probe tells a readable file, a missing one and a refused one apart")
    func probeClassifies() throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let readable = directory.appendingPathComponent("ok")
        try Data("x".utf8).write(to: readable)
        let denied = try deniedFile(in: directory, named: "denied")

        #expect(FileAccess.probe(readable.path) == .readable)
        #expect(FileAccess.probe(directory.appendingPathComponent("absent").path) == .missing)
        #expect(FileAccess.probe(denied.path) == .denied)
        // A path under a file is "not a directory", which is absence, not a refusal.
        #expect(FileAccess.probe(readable.appendingPathComponent("below").path) == .missing)
    }

    @Test("Probing a FIFO returns at once instead of waiting for a writer", .timeLimit(.minutes(1)))
    func probeDoesNotBlockOnAFifo() throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appendingPathComponent("pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(FileAccess.probe(fifo.path) == .readable)
    }

    @Test("EPERM — what macOS answers a missing privacy grant with — is a denial, like EACCES")
    func errnoMapping() {
        #expect(FileAccess.classify(EPERM) == .denied)
        #expect(FileAccess.classify(EACCES) == .denied)
        #expect(FileAccess.classify(ENOENT) == .missing)
        #expect(FileAccess.classify(ENOTDIR) == .missing)
        #expect(FileAccess.classify(EIO) == .other(EIO))
        #expect(FileAccess.classify(ELOOP) == .other(ELOOP))
    }

    @Test("Damage codes are told apart from a permission refusal, extended codes included")
    func damageClassification() {
        typealias Open = ReadOnlyDatabase.OpenFailure
        #expect(Open(code: SQLITE_IOERR, detail: "").isDamaged)
        #expect(Open(code: SQLITE_CORRUPT, detail: "").isDamaged)
        #expect(Open(code: SQLITE_NOTADB, detail: "").isDamaged)
        #expect(Open(code: SQLITE_CANTOPEN, detail: "").isDamaged)
        #expect(Open(code: SQLITE_IOERR | (1 << 8), detail: "").isDamaged)  // extended result code
        // A cannot-open that is really a refusal must not trigger a pointless recopy.
        #expect(!Open(code: SQLITE_CANTOPEN, detail: "", systemErrno: EPERM).isDamaged)
        #expect(!Open(code: SQLITE_AUTH, detail: "").isDamaged)
        #expect(!Open(code: SQLITE_BUSY, detail: "").isDamaged)
        #expect(ReadOnlyDatabase.QueryFailure(sql: "", detail: "", code: SQLITE_IOERR).isDamaged)
        #expect(!ReadOnlyDatabase.QueryFailure(sql: "", detail: "", code: SQLITE_ERROR).isDamaged)
    }

    @Test("SQLite's refusal codes and errno values all count as a denial; absence does not")
    func openFailureClassification() {
        typealias Failure = ReadOnlyDatabase.OpenFailure
        #expect(Failure(code: SQLITE_AUTH, detail: "authorization denied").isPermissionDenied)
        #expect(Failure(code: SQLITE_PERM, detail: "").isPermissionDenied)
        #expect(Failure(code: SQLITE_CANTOPEN, detail: "", systemErrno: EPERM).isPermissionDenied)
        #expect(Failure(code: SQLITE_CANTOPEN, detail: "", systemErrno: EACCES).isPermissionDenied)
        #expect(!Failure(code: SQLITE_CANTOPEN, detail: "", systemErrno: ENOENT).isPermissionDenied)
        #expect(!Failure(code: SQLITE_NOTADB, detail: "").isPermissionDenied)
    }

    @Test("A chat store macOS refuses is reported as a refusal, with the steps")
    func chatStoreDenial() async throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try deniedFile(in: directory)
        let store = SystemWhatsAppStore(path: file.path)

        #expect(store.availability() == .accessDenied(path: file.path))

        let tools = WhatsAppTools(store: store, calendar: Fixtures.calendar)
        let (chats, chatsError) = await call(tools, ToolCatalog.chatsName)
        #expect(chatsError)
        #expect(chats.contains("Full Disk Access"))
        #expect(chats.contains("needs Full Disk"), "the sentence that says what is needed")
        #expect(chats.contains("Privacy & Security"))
        #expect(chats.contains("after every update"))
        #expect(!chats.localizedCaseInsensitiveContains("not a permissions problem"))

        let (status, _) = await call(tools, ToolCatalog.statusName)
        #expect(status.contains("ACCESS DENIED"))
        #expect(status.contains("permission: DENIED by macOS"))
        #expect(!status.contains("none needed"))
        #expect(!status.contains("NOT FOUND"))
    }

    @Test("A path with nothing at it is still 'not found', and says it is not a refusal")
    func missingIsNotDenied() async throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SystemWhatsAppStore(path: directory.appendingPathComponent("ChatStorage.sqlite").path)
        #expect(store.availability() == .databaseMissing(path: store.databaseInfo().path))

        let tools = WhatsAppTools(store: store, calendar: Fixtures.calendar)
        let (chats, isError) = await call(tools, ToolCatalog.chatsName)
        #expect(isError)
        #expect(chats.contains("not a refusal"))
        #expect(!chats.contains("Full Disk Access"))
        let (status, _) = await call(tools, ToolCatalog.statusName)
        #expect(status.contains("NOT FOUND"))
        #expect(status.contains("not the problem shown above"))
    }

    @Test("A readable store reports the permission as allowed")
    func readableStatus() async {
        let tools = WhatsAppTools(store: FakeWhatsAppStore(), calendar: Fixtures.calendar)
        let (status, _) = await call(tools, ToolCatalog.statusName)
        #expect(status.contains("permission: macOS allowed this server to read it"))
    }

    @Test("A database the cache cannot read from the container is a refusal, not 'missing'")
    func snapshotDenial() async throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = directory.appendingPathComponent("container")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        _ = try deniedFile(in: container, named: "ContactsV2.sqlite")
        let cache = SnapshotCache(
            containerDirectory: container, cacheDirectory: directory.appendingPathComponent("cache"))
        let tools = WhatsAppTools(
            store: FakeWhatsAppStore(), explorer: SnapshotDatabaseExplorer(cache: cache),
            reader: SnapshotDomainReader(cache: cache), calendar: Fixtures.calendar)

        for (tool, arguments) in [
            (ToolCatalog.dbTablesName, ["db": Value.string("ContactsV2")]),
            (ToolCatalog.addressBookName, [:]),
        ] {
            let (text, isError) = await call(tools, tool, arguments)
            #expect(isError, Comment(rawValue: tool))
            #expect(text.contains("Full Disk Access"), Comment(rawValue: "\(tool): \(text)"))
            #expect(!text.contains("returned an error"))
        }
        // Nothing half-made was left in the cache.
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: directory.appendingPathComponent("cache").path)) ?? []
        #expect(leftovers.filter { $0.contains("tmp") || $0.hasSuffix(".sqlite") }.isEmpty, "\(leftovers)")
    }

    @Test("An attachment macOS refuses to open is a refusal, never 'not an image' or 'not on this Mac'")
    func mediaDenial() async throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("Message")
        let media = root.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let file = try deniedFile(in: media, named: "photo.jpg")

        let store = FakeWhatsAppStore()
        store.messagesValue = [
            Fixtures.message(
                id: 10, chatID: 1, chatName: "Ane", text: nil,
                body: Fixtures.attachment(.photo, path: file.path)),
            Fixtures.message(
                id: 11, chatID: 1, chatName: "Ane", text: nil,
                body: Fixtures.attachment(.voiceNote, path: file.path, duration: 5)),
        ]
        let tools = WhatsAppTools(
            store: store, mediaFiles: MediaFiles(root: root),
            transcription: TranscriptionService(
                mediaFiles: MediaFiles(root: root), cacheDirectory: directory.appendingPathComponent("cache"),
                converter: nil, engine: UnusedEngine()),
            calendar: Fixtures.calendar)

        for (tool, arguments) in [
            (ToolCatalog.mediaGetName, ["message_id": Value.int(10)]),
            (ToolCatalog.mediaViewName, ["message_id": Value.int(10)]),
            (ToolCatalog.audioTranscribeName, ["message_id": Value.int(11), "language": Value.string("es-ES")]),
        ] {
            let (text, isError) = await call(tools, tool, arguments)
            #expect(isError, Comment(rawValue: tool))
            #expect(text.contains("Full Disk Access"), Comment(rawValue: "\(tool): \(text)"))
            #expect(!text.contains("not an image") && !text.contains("not on this Mac"))
        }
    }
}

/// Fails the test if the engine is ever reached: a refused file must be stopped before it.
private struct UnusedEngine: SpeechTranscribing {
    func resolveLocale(_ requested: String?) async throws -> String { "es-ES" }
    func transcribe(audio: URL, locale: String) async throws -> [TranscriptSegment] {
        Issue.record("the engine was reached for a file that could not be opened")
        return []
    }
}
