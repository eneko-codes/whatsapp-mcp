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

    @Test("The raw backup is owner-only and registered for cleanup from its first byte, while it holds the keys",
          .timeLimit(.minutes(2)))
    func temporariesAreOwnerOnlyAndRegisteredWhileTheCopyRuns() async throws {
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
        let observed = ObservedTemporaries()
        let watcher = Task.detached {
            while !Task.isCancelled {
                for name in (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []
                where name.contains(".tmp-") {
                    let url = cache.appendingPathComponent(name)
                    if let found = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int {
                        // Registered at the moment it was seen, which is the property: a signal
                        // arriving now would delete it.
                        // A journal or WAL file is covered by its database's registration: the
                        // cleanup deletes the registered path and each of these suffixes.
                        var base = url.path
                        for suffix in ["-journal", "-wal", "-shm"] where base.hasSuffix(suffix) {
                            base = String(base.dropLast(suffix.count))
                        }
                        observed.record(mode: found, registered: ProcessCleanup.shared.registeredPaths.contains(base))
                    }
                }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        // The default umask (022) is what would have made the old code's files 0644.
        _ = try SnapshotCache(containerDirectory: container, cacheDirectory: cache).snapshot(of: .extendedChat)
        watcher.cancel()

        #expect(!observed.modes.isEmpty, "the copy was too quick to observe")
        #expect(observed.modes.allSatisfy { $0 == 0o600 }, "temporary modes seen: \(Set(observed.modes).map { String($0, radix: 8) })")
        #expect(observed.unregistered == 0, "a temporary existed while not registered for cleanup")
        #expect(ProcessCleanup.shared.registeredPaths.filter { $0.contains(".tmp-") }.isEmpty, "left registered after the copy")
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

    @Test("A symlinked tmp directory is not swept, and a scratch dir with a recent file inside is kept")
    func sweepIsCareful() throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let longAgo = Date().addingTimeInterval(-7200)

        // tmp -> somewhere else, containing an old file the sweep must not touch.
        let elsewhere = directory.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let precious = elsewhere.appendingPathComponent("precious")
        try Data("x".utf8).write(to: precious)
        try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: precious.path)
        let linkedCache = directory.appendingPathComponent("linked-cache")
        try FileManager.default.createDirectory(at: linkedCache, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: linkedCache.appendingPathComponent("tmp"), withDestinationURL: elsewhere)
        SnapshotCache.sweepStaleTemporaries(in: linkedCache)
        #expect(FileManager.default.fileExists(atPath: precious.path), "the sweep followed a symlink")

        // A conversion that has been running for hours: old directory, fresh output file.
        let cache = directory.appendingPathComponent("cache")
        let running = cache.appendingPathComponent("tmp/long-conversion")
        try FileManager.default.createDirectory(at: running, withIntermediateDirectories: true)
        try Data("wav".utf8).write(to: running.appendingPathComponent("audio.wav"))
        try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: running.path)
        SnapshotCache.sweepStaleTemporaries(in: cache)
        #expect(FileManager.default.fileExists(atPath: running.path), "a live conversion was swept")
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

}

private final class ObservedTemporaries: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [Int] = []
    private var missed = 0
    func record(mode: Int, registered: Bool) {
        lock.withLock {
            seen.append(mode)
            if !registered { missed += 1 }
        }
    }
    var modes: [Int] { lock.withLock { seen } }
    var unregistered: Int { lock.withLock { missed } }
}


/// The built server, started for real, stopped for real.
///
/// Off unless `WHATSAPP_MCP_E2E` is set, because it needs the debug binary to be built
/// (`swift build`, which `swift test` alone does not do) and the en-US speech model installed:
/// the conversion it interrupts is reached only after the real engine accepts the language.
/// `WHATSAPP_MCP_E2E=1 swift build && WHATSAPP_MCP_E2E=1 swift test --filter ServerLifecycle`.
@Suite("ServerLifecycle", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["WHATSAPP_MCP_E2E"] != nil))
struct ServerLifecycleTests {

    static let serverBinary: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/whatsapp-mcp")
    }()

    private struct Running {
        let directory: URL
        let server: Process
        let input: Pipe
        let ffmpegPID: Int32
        let scratch: URL
    }

    private func waitFor(seconds: Double = 15, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    /// Starts the server and gets it into the middle of a conversion: ffmpeg running, scratch
    /// directory made. Everything is polled, never waited on, so a stuck child cannot block a
    /// cooperative thread and defeat the time limit.
    private func startMidConversion() async throws -> Running {
        let binary = Self.serverBinary
        try #require(FileManager.default.isExecutableFile(atPath: binary.path),
                     "build the debug binary first: swift build")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("whatsapp-lifecycle-\(UUID().uuidString)")
        let container = directory.appendingPathComponent("container")
        let media = container.appendingPathComponent("Message/Media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        // Looks like Ogg to the sniffer, is not decodable by macOS, so the converter is used.
        try (Data("OggS".utf8) + Data("not real".utf8)).write(to: media.appendingPathComponent("note.opus"))

        let pidFile = directory.appendingPathComponent("ffmpeg.pid")
        let ffmpeg = directory.appendingPathComponent("ffmpeg-hang")
        try Data("#!/bin/sh\necho $$ > '\(pidFile.path)'\nexec sleep 120\n".utf8).write(to: ffmpeg)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ffmpeg.path)

        let cache = directory.appendingPathComponent("cache")
        let server = Process()
        server.executableURL = binary
        server.arguments = [
            "--database", container.appendingPathComponent("ChatStorage.sqlite").path,
            "--cache-directory", cache.path, "--ffmpeg", ffmpeg.path,
        ]
        let input = Pipe()
        server.standardInput = input
        server.standardOutput = Pipe()
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

        let started = await waitFor { FileManager.default.fileExists(atPath: pidFile.path) }
        guard started else {
            server.terminate()
            Issue.record("ffmpeg never started — is the en-US speech model installed?")
            throw CancellationError()
        }
        let text = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(Int32(text))
        let scratch = cache.appendingPathComponent("tmp")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: scratch.path))?.isEmpty == false,
                "the scratch directory should exist mid-conversion")
        return Running(directory: directory, server: server, input: input, ffmpegPID: pid, scratch: scratch)
    }

    private func assertCleanedUp(_ run: Running, expectedStatus: Int32) async {
        let exited = await waitFor { !run.server.isRunning }
        #expect(exited, "the server did not exit")
        if exited { #expect(run.server.terminationStatus == expectedStatus) }
        #expect(await waitFor { kill(run.ffmpegPID, 0) != 0 }, "ffmpeg survived the server")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: run.scratch.path))?.isEmpty ?? true,
                "the scratch directory was left behind")
    }

    @Test("A signal mid-conversion kills ffmpeg, removes the scratch directory and exits 128+n",
          .timeLimit(.minutes(2)), arguments: [SIGTERM, SIGINT, SIGHUP])
    func signalCleansUp(signalNumber: Int32) async throws {
        let run = try await startMidConversion()
        defer { try? FileManager.default.removeItem(at: run.directory); if run.server.isRunning { run.server.terminate() } }
        kill(run.server.processIdentifier, signalNumber)
        await assertCleanedUp(run, expectedStatus: 128 + signalNumber)
    }

    @Test("A client that closes stdin mid-conversion leaves nothing behind either", .timeLimit(.minutes(2)))
    func stdinCloseCleansUp() async throws {
        let run = try await startMidConversion()
        defer { try? FileManager.default.removeItem(at: run.directory); if run.server.isRunning { run.server.terminate() } }
        try run.input.fileHandleForWriting.close()
        await assertCleanedUp(run, expectedStatus: 0)
    }

    @Test("A client that disappears (SIGPIPE) leaves nothing behind", .timeLimit(.minutes(2)))
    func sigpipeCleansUp() async throws {
        let run = try await startMidConversion()
        defer { try? FileManager.default.removeItem(at: run.directory); if run.server.isRunning { run.server.terminate() } }
        kill(run.server.processIdentifier, SIGPIPE)
        await assertCleanedUp(run, expectedStatus: 128 + SIGPIPE)
    }
}
