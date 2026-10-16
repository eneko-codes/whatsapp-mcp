import Foundation
import SQLite3
import Testing

@testable import WhatsAppMCPCore

@Suite("Temporary files and child processes do not outlive their work")
struct CleanupTests {

    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whatsapp-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func mode(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
    }

    @Test("The raw backup is owner-only from its first byte, while it still holds the keys",
          .timeLimit(.minutes(2)))
    func temporariesAreOwnerOnlyWhileTheCopyRuns() async throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = directory.appendingPathComponent("container")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)

        // ~96 MB, so the copy, the scrub and the rebuild take long enough to be observed.
        var handle: OpaquePointer?
        let source = container.appendingPathComponent("ExtChatDB").appendingPathComponent("ExtChatDatabase.sqlite")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(sqlite3_open(source.path, &handle) == SQLITE_OK)
        for statement in [
            "CREATE TABLE feature_key_store (_id INTEGER PRIMARY KEY, key BLOB)",
            "CREATE TABLE filler (b BLOB)",
            "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 96) INSERT INTO filler SELECT zeroblob(1000000) FROM n",
        ] {
            #expect(sqlite3_exec(handle, statement, nil, nil, nil) == SQLITE_OK)
        }
        sqlite3_close(handle)

        let cache = directory.appendingPathComponent("cache")
        let observed = ObservedModes()
        let watcher = Task.detached {
            while !Task.isCancelled {
                for name in (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []
                where name.contains(".tmp-") {
                    let url = cache.appendingPathComponent(name)
                    if let found = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int {
                        observed.record(found)
                    }
                }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        // A permissive umask is what would have made the old code's files 0644/0666.
        let previous = umask(0)
        defer { umask(previous) }
        _ = try SnapshotCache(containerDirectory: container, cacheDirectory: cache).snapshot(of: .extendedChat)
        watcher.cancel()

        let modes = observed.values
        #expect(!modes.isEmpty, "the copy was too quick to observe")
        #expect(modes.allSatisfy { $0 == 0o600 }, "temporary modes seen: \(Set(modes).map { String($0, radix: 8) })")
    }

    @Test("Temporaries a dead process left are swept, a live process's are not")
    func staleTemporariesAreSwept() throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory
        try FileManager.default.createDirectory(at: cache.appendingPathComponent("tmp/old-run"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache.appendingPathComponent("tmp/live-run"), withIntermediateDirectories: true)
        let oldBackup = cache.appendingPathComponent("ChatStorage.sqlite.tmp-OLD")
        let oldRebuilt = cache.appendingPathComponent("ChatStorage.sqlite.tmp-OLD.rebuilt")
        let liveBackup = cache.appendingPathComponent("ChatStorage.sqlite.tmp-LIVE")
        let unrelated = cache.appendingPathComponent("notes.txt")
        for url in [oldBackup, oldRebuilt, liveBackup, unrelated] { try Data("x".utf8).write(to: url) }

        let longAgo = Date().addingTimeInterval(-7200)
        for url in [oldBackup, oldRebuilt, unrelated, cache.appendingPathComponent("tmp/old-run")] {
            try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: url.path)
        }

        SnapshotCache.sweepStaleTemporaries(in: cache)

        let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: cache.path))
        #expect(!remaining.contains("ChatStorage.sqlite.tmp-OLD"))
        #expect(!remaining.contains("ChatStorage.sqlite.tmp-OLD.rebuilt"))
        #expect(remaining.contains("ChatStorage.sqlite.tmp-LIVE"), "a recent temporary may be another instance's")
        #expect(remaining.contains("notes.txt"), "only this server's own temporaries are touched")
        #expect(!FileManager.default.fileExists(atPath: cache.appendingPathComponent("tmp/old-run").path))
        #expect(FileManager.default.fileExists(atPath: cache.appendingPathComponent("tmp/live-run").path))
    }

    @Test("The cleanup registry deletes registered files and kills registered children")
    func registryCleans() throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("half-made.sqlite.tmp-1")
        try Data("keys".utf8).write(to: file)
        let kept = directory.appendingPathComponent("unregistered")
        try Data("keep".utf8).write(to: kept)
        // Its own registry, not `shared`: run() on the shared one would delete the files and kill
        // the children of every other test running at the same time.
        let registry = ProcessCleanup()
        registry.register(path: file.path)

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["60"]
        try child.run()
        registry.register(child: child)
        #expect(child.isRunning)

        registry.run()
        child.waitUntilExit()

        #expect(!child.isRunning)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: kept.path))
        registry.run()  // twice is harmless
    }

    @Test("A SIGTERM mid-conversion kills ffmpeg, removes the scratch directory and exits 143",
          .enabled(if: FileManager.default.isExecutableFile(atPath: CleanupTests.serverBinary.path)),
          .timeLimit(.minutes(2)))
    func sigtermCleansUp() async throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = directory.appendingPathComponent("container")
        let media = container.appendingPathComponent("Message/Media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        // Looks like Ogg to the sniffer, is not decodable by macOS, so the converter is used.
        try Data("OggS".utf8 + Data("not real".utf8)).write(to: media.appendingPathComponent("note.opus"))

        let pidFile = directory.appendingPathComponent("ffmpeg.pid")
        let ffmpeg = directory.appendingPathComponent("ffmpeg-hang")
        try Data("#!/bin/sh\necho $$ > '\(pidFile.path)'\nexec sleep 120\n".utf8).write(to: ffmpeg)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ffmpeg.path)

        let cache = directory.appendingPathComponent("cache")
        let server = Process()
        server.executableURL = Self.serverBinary
        server.arguments = [
            "--database", container.appendingPathComponent("ChatStorage.sqlite").path,
            "--cache-directory", cache.path, "--ffmpeg", ffmpeg.path,
        ]
        let input = Pipe(), output = Pipe()
        server.standardInput = input
        server.standardOutput = output
        server.standardError = FileHandle.nullDevice
        try server.run()
        func send(_ object: [String: Any]) throws {
            input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: object) + Data("\n".utf8))
        }
        try send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
            "protocolVersion": "2024-11-05", "capabilities": [:], "clientInfo": ["name": "t", "version": "0"]]])
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        try send(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": [
            "name": "audio_transcribe",
            "arguments": ["path": media.appendingPathComponent("note.opus").path, "language": "en-US"]]])

        func waitFor(_ condition: () -> Bool) async -> Bool {
            for _ in 0..<150 { if condition() { return true }; try? await Task.sleep(nanoseconds: 100_000_000) }
            return condition()
        }
        let started = await waitFor { FileManager.default.fileExists(atPath: pidFile.path) }
        try #require(started, "ffmpeg never started — is the en-US speech model installed?")
        let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        let scratch = cache.appendingPathComponent("tmp")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: scratch.path))?.isEmpty == false,
                "the scratch directory should exist mid-conversion")

        kill(server.processIdentifier, SIGTERM)
        server.waitUntilExit()

        #expect(server.terminationStatus == 128 + SIGTERM)
        #expect(await waitFor { kill(pid, 0) != 0 }, "ffmpeg survived the server")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: scratch.path))?.isEmpty ?? true)
    }

    static let serverBinary: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/whatsapp-mcp")
    }()
}

private final class ObservedModes: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [Int] = []
    func record(_ mode: Int) { lock.withLock { seen.append(mode) } }
    var values: [Int] { lock.withLock { seen } }
}
