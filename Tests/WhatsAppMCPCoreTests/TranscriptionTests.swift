import AVFoundation
import Foundation
import MCP
import Testing

@testable import WhatsAppMCPCore

/// A speech engine that recognises nothing and records what it was asked. The real engine
/// needs a language model installed and real audio; the pipeline around it — conversion,
/// caching, cleanup, argument handling — does not, and is what these tests cover.
private final class FakeEngine: SpeechTranscribing, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [(URL, String)] = []
    var segments = [TranscriptSegment(start: 0.0, end: 2.5, text: "invented words")]

    var transcribeCount: Int { lock.withLock { requests.count } }

    func resolveLocale(_ requested: String?) async throws -> String {
        guard let requested, !requested.isEmpty else {
            throw TranscriptionError.noLanguage(supported: ["en-US", "es-ES"])
        }
        switch requested.lowercased() {
        case "es", "es-es": return "es-ES"
        case "en", "en-us": return "en-US"
        default:
            throw TranscriptionError.unsupportedLanguage(
                requested: requested, supported: ["en-US", "es-ES"])
        }
    }

    func transcribe(audio: URL, locale: String) async throws -> [TranscriptSegment] {
        lock.withLock { requests.append((audio, locale)) }
        return segments
    }
}

/// The fixture below, reachable from the suites in this file that are not its owner.
struct TranscriptionFixtureShim {
    private let inner: TranscriptionFixture
    init() throws { inner = try TranscriptionFixture() }
    var directory: URL { inner.directory }
    var root: URL { inner.root }
    var media: URL { inner.media }
    var cache: URL { inner.cache }
    var engine: any SpeechTranscribing { inner.engine }
    var transcribeCount: Int { inner.engine.transcribeCount }
    func remove() { inner.remove() }
    func fakeFFmpeg(succeeding: Bool = true) throws -> FFmpegConverter { try inner.fakeFFmpeg(succeeding: succeeding) }
    func ffmpegRuns() -> [String] { inner.ffmpegRuns() }
}

/// A file that starts like an Ogg stream — all ffmpeg's demuxer pinning looks at — followed by
/// invented bytes. A real Opus stream is not needed: the fake ffmpeg ignores its input.
func oggBytes(_ tail: String) -> Data { Data("OggS".utf8) + Data(tail.utf8) }

private struct TranscriptionFixture {
    let directory: URL
    var root: URL { directory.appendingPathComponent("Message") }
    var media: URL { root.appendingPathComponent("Media") }
    var cache: URL { directory.appendingPathComponent("cache") }
    var bin: URL { directory.appendingPathComponent("bin") }
    var runsLog: URL { bin.appendingPathComponent("runs.log") }
    let engine = FakeEngine()

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("whatsapp-transcription-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    /// A one-second silent 16 kHz mono WAV, which AVFoundation reads natively.
    func makeWAV(named name: String, in folder: URL? = nil) throws -> URL {
        let url = (folder ?? media).appendingPathComponent(name)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
        buffer.frameLength = 16000
        try file.write(from: buffer)
        return url
    }

    /// An ffmpeg that never finishes: records its process id, then becomes `sleep`.
    func hangingFFmpeg() throws -> (FFmpegConverter, pidFile: URL) {
        let pidFile = bin.appendingPathComponent("hang.pid")
        let script = bin.appendingPathComponent("ffmpeg-hang")
        try Data("#!/bin/sh\necho $$ > '\(pidFile.path)'\nexec sleep 60\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (FFmpegConverter(executable: script), pidFile)
    }

    /// A stand-in for ffmpeg: logs its arguments and the run, then writes a prepared WAV to
    /// its last argument. The script is plain `sh`, written here and read by nobody else.
    func fakeFFmpeg(succeeding: Bool = true) throws -> FFmpegConverter {
        let prepared = try makeWAV(named: "prepared.wav", in: bin)
        let script = bin.appendingPathComponent("ffmpeg")
        let body =
            succeeding
            ? """
            #!/bin/sh
            echo "$@" >> '\(runsLog.path)'
            for last; do :; done
            cp '\(prepared.path)' "$last"
            """
            : """
            #!/bin/sh
            echo "$@" >> '\(runsLog.path)'
            echo "invented conversion failure" >&2
            exit 1
            """
        try Data(body.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return FFmpegConverter(executable: script)
    }

    func ffmpegRuns() -> [String] {
        ((try? String(contentsOf: runsLog, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    func service(converter: FFmpegConverter?) -> TranscriptionService {
        TranscriptionService(
            mediaFiles: MediaFiles(root: root), scratchDirectory: cache, converter: converter,
            engine: engine)
    }

    func tools(converter: FFmpegConverter?, messages: [WhatsAppMCPCore.Message] = []) -> WhatsAppTools {
        let store = FakeWhatsAppStore()
        store.messagesValue = messages
        return WhatsAppTools(
            store: store, mediaFiles: MediaFiles(root: root),
            transcription: service(converter: converter), calendar: Fixtures.calendar)
    }

    func voiceNote(id: Int64, path: String?) -> WhatsAppMCPCore.Message {
        Fixtures.message(
            id: id, chatID: 1, chatName: "Ane", text: nil,
            body: Fixtures.attachment(.voiceNote, path: path, duration: 33))
    }
}

private func run(
    _ tools: WhatsAppTools, _ arguments: [String: Value]
) async -> (text: String, isError: Bool) {
    let result = await tools.handle(.init(name: ToolCatalog.audioTranscribeName, arguments: arguments))
    guard case .text(let text, _, _) = result.content.first else { return ("(none)", true) }
    return (text, result.isError ?? false)
}

@Suite("Audio transcription")
struct TranscriptionTests {

    @Test("A voice note in a format macOS cannot open is converted, transcribed and timed")
    func opusIsConvertedThenTranscribed() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        let opus = fixture.media.appendingPathComponent("note.opus")
        try oggBytes("not really opus").write(to: opus)
        let tools = fixture.tools(
            converter: try fixture.fakeFFmpeg(), messages: [fixture.voiceNote(id: 7, path: opus.path)])

        let (text, isError) = await run(tools, ["message_id": .int(7), "language": .string("es")])
        #expect(!isError, Comment(rawValue: text))
        #expect(text.contains("AUTOMATIC TRANSCRIPTION"))
        #expect(text.contains("language es-ES"))
        #expect(text.contains("duration 0:01"))
        #expect(text.contains("[0:00–0:02] invented words"))
        #expect(text.contains("can contain errors"))

        // ffmpeg ran on this one file, local files only, sound only.
        let runs = fixture.ffmpegRuns()
        #expect(runs.count == 1)
        #expect(runs[0].contains("-protocol_whitelist file"))
        #expect(runs[0].contains("-vn"))
        #expect(runs[0].contains(opus.path))
        #expect(runs[0].contains("-nostdin"))
    }

    @Test("A second request for the same audio recognises it again: nothing is cached")
    func secondRequestRunsAgain() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        let opus = fixture.media.appendingPathComponent("note.opus")
        try oggBytes("not really opus").write(to: opus)
        let tools = fixture.tools(
            converter: try fixture.fakeFFmpeg(), messages: [fixture.voiceNote(id: 7, path: opus.path)])

        _ = await run(tools, ["message_id": .int(7), "language": .string("es-ES")])
        let (again, isError) = await run(tools, ["message_id": .int(7), "language": .string("es-ES")])
        #expect(!isError)
        #expect(!again.contains("cache"))
        #expect(fixture.engine.transcribeCount == 2)
        #expect(fixture.ffmpegRuns().count == 2)

        _ = await run(tools, ["message_id": .int(7), "language": .string("en")])
        #expect(fixture.engine.transcribeCount == 3)
    }

    @Test("Nothing is kept: the same audio is recognised again, and no transcript is ever written")
    func nothingIsStored() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        let first = fixture.media.appendingPathComponent("a.opus")
        let second = fixture.media.appendingPathComponent("b.opus")
        try oggBytes("same bytes").write(to: first)
        try oggBytes("same bytes").write(to: second)
        let service = fixture.service(converter: try fixture.fakeFFmpeg())

        _ = try await service.transcribe(file: first, language: "es")
        _ = try await service.transcribe(file: second, language: "es")
        #expect(fixture.engine.transcribeCount == 2)

        // Whatever the scratch directory holds, nothing of the transcript is in it: only the
        // (empty) folder the conversions are made in.
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: fixture.cache.path)) ?? []
        #expect(entries.filter { $0 != "tmp" }.isEmpty, "\(entries)")
        #expect(!FileManager.default.fileExists(
            atPath: fixture.cache.appendingPathComponent("transcripts").path))
    }

    @Test("The scratch WAV is deleted and the scratch directory is private")
    func scratchIsCleanedAndPrivate() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        let opus = fixture.media.appendingPathComponent("note.opus")
        try oggBytes("x").write(to: opus)
        _ = try await fixture.service(converter: try fixture.fakeFFmpeg())
            .transcribe(file: opus, language: "es")

        let scratch = fixture.cache.appendingPathComponent("tmp")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []
        #expect(leftovers.isEmpty, "scratch not cleaned: \(leftovers)")

        func mode(_ url: URL) throws -> Int? {
            try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        }
        #expect(try mode(fixture.cache) == 0o700)
        #expect(try mode(scratch) == 0o700)
    }

    @Test("Nothing is written outside the scratch directory and the file is left as it was")
    func nothingElseIsWritten() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        let opus = fixture.media.appendingPathComponent("note.opus")
        try oggBytes("original bytes").write(to: opus)
        let before = try Data(contentsOf: opus)
        let mediaListing = try FileManager.default.contentsOfDirectory(atPath: fixture.media.path)

        _ = try await fixture.service(converter: try fixture.fakeFFmpeg())
            .transcribe(file: opus, language: "es")

        #expect(try Data(contentsOf: opus) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.media.path) == mediaListing)
    }

    @Test("Audio macOS opens itself needs no converter at all")
    func nativeFormatSkipsFFmpeg() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        let wav = try fixture.makeWAV(named: "note.wav")
        let result = try await fixture.service(converter: nil).transcribe(file: wav, language: "en")
        #expect(result.localeIdentifier == "en-US")
        #expect(result.segments.count == 1)
    }

    @Test("Without ffmpeg an Ogg Opus voice note gets a clear instruction, not a guess")
    func missingConverterIsExplained() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        let opus = fixture.media.appendingPathComponent("note.opus")
        try oggBytes("x").write(to: opus)
        let tools = fixture.tools(converter: nil, messages: [fixture.voiceNote(id: 7, path: opus.path)])
        let (text, isError) = await run(tools, ["message_id": .int(7), "language": .string("es")])
        #expect(isError)
        #expect(text.contains("brew install ffmpeg"))
        #expect(fixture.engine.transcribeCount == 0)
    }

    private func isAlive(_ pidFile: URL) -> Bool {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
            let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        return kill(pid, 0) == 0
    }

    private func waitUntil(_ condition: () -> Bool, seconds: Double = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    @Test("A hung ffmpeg is stopped at the time limit instead of holding the call")
    func hungConverterIsStopped() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        var (converter, pidFile) = try fixture.hangingFFmpeg()
        converter.timeout = 0.4
        let input = fixture.media.appendingPathComponent("note.opus")
        try oggBytes("x").write(to: input)

        let started = Date()
        await #expect(throws: TranscriptionError.conversionFailed("it ran past 0 seconds and was stopped")) {
            try await converter.convert(input, to: fixture.bin.appendingPathComponent("out.wav"))
        }
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(await waitUntil({ !isAlive(pidFile) }), "ffmpeg is still running")
    }

    @Test("Cancelling the request kills ffmpeg")
    func cancellationKillsConverter() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        let (converter, pidFile) = try fixture.hangingFFmpeg()
        let input = fixture.media.appendingPathComponent("note.opus")
        try oggBytes("x").write(to: input)

        let task = Task {
            try await converter.convert(input, to: fixture.bin.appendingPathComponent("out.wav"))
        }
        #expect(await waitUntil({ isAlive(pidFile) }), "ffmpeg never started")
        task.cancel()
        _ = await task.result
        #expect(await waitUntil({ !isAlive(pidFile) }), "ffmpeg survived cancellation")
    }

    @Test("A pre-existing scratch directory keeps its mode; one this server creates is private")
    func onlyCreatedDirectoriesAreChmodded() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        let shared = fixture.directory.appendingPathComponent("shared")
        try FileManager.default.createDirectory(
            at: shared, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        let opus = fixture.media.appendingPathComponent("note.opus")
        try oggBytes("x").write(to: opus)

        let service = TranscriptionService(
            mediaFiles: MediaFiles(root: fixture.root), scratchDirectory: shared,
            converter: try fixture.fakeFFmpeg(), engine: fixture.engine)
        _ = try await service.transcribe(file: opus, language: "es")

        func mode(_ url: URL) throws -> Int? {
            try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        }
        #expect(try mode(shared) == 0o755, "an existing directory was chmodded")
        #expect(try mode(shared.appendingPathComponent("tmp")) == 0o700)
    }

    @Test("A video gets its frames with a note, never a failure, when the transcript cannot be made")
    func videoTranscriptIsBestEffort() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        let clip = fixture.media.appendingPathComponent("clip.mp4")
        try await makeVideo(at: clip)
        let video = Fixtures.message(
            id: 9, chatID: 1, chatName: "Ane", text: nil,
            body: Fixtures.attachment(.video, path: clip.path))
        // ffmpeg fails, so the transcript cannot be produced.
        let tools = fixture.tools(
            converter: try fixture.fakeFFmpeg(succeeding: false), messages: [video])

        func view(_ arguments: [String: Value]) async -> (content: [Tool.Content], isError: Bool) {
            let result = await tools.handle(.init(name: ToolCatalog.mediaViewName, arguments: arguments))
            return (result.content, result.isError ?? false)
        }
        func summary(_ content: [Tool.Content]) -> String {
            content.compactMap { if case .text(let text, _, _) = $0 { text } else { nil } }
                .joined(separator: "\n")
        }

        let (noLanguage, noLanguageError) = await view(["message_id": .int(9), "frames": .int(2)])
        #expect(!noLanguageError)
        #expect(summary(noLanguage).contains("pass 'language'"))
        #expect(fixture.engine.transcribeCount == 0)

        let (failed, failedError) = await view(
            ["message_id": .int(9), "frames": .int(2), "language": .string("es-ES")])
        #expect(!failedError, Comment(rawValue: summary(failed)))
        #expect(summary(failed).contains("No transcript"))
        #expect(failed.filter { if case .image = $0 { true } else { false } }.count == 2)
    }

    @Test("A failing ffmpeg is reported with its own message and leaves nothing behind")
    func failingConverterIsReported() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        let opus = fixture.media.appendingPathComponent("note.opus")
        try oggBytes("x").write(to: opus)
        let tools = fixture.tools(
            converter: try fixture.fakeFFmpeg(succeeding: false),
            messages: [fixture.voiceNote(id: 7, path: opus.path)])
        let (text, isError) = await run(tools, ["message_id": .int(7), "language": .string("es")])
        #expect(isError)
        #expect(text.contains("invented conversion failure"))
        let leftovers =
            (try? FileManager.default.contentsOfDirectory(
                atPath: fixture.cache.appendingPathComponent("tmp").path)) ?? []
        #expect(leftovers.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.cache.appendingPathComponent("transcripts").path))
    }

    @Test("Basque is refused with a clear error and never transcribed in another language")
    func basqueIsRefused() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        let wav = try fixture.makeWAV(named: "note.wav")
        let tools = fixture.tools(
            converter: nil, messages: [fixture.voiceNote(id: 7, path: wav.path)])
        for language in ["eu", "eu-ES", "ca"] {
            let (text, isError) = await run(
                tools, ["message_id": .int(7), "language": .string(language)])
            #expect(isError, Comment(rawValue: language))
            #expect(text.contains("has no model for '\(language)'"), Comment(rawValue: text))
            #expect(text.contains("does not substitute another language"))
        }
        #expect(fixture.engine.transcribeCount == 0)
    }

    @Test("A language is required: this Mac's own language is never assumed")
    func missingLanguageIsRefused() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        let wav = try fixture.makeWAV(named: "note.wav")
        let tools = fixture.tools(
            converter: nil, messages: [fixture.voiceNote(id: 7, path: wav.path)])
        let (text, isError) = await run(tools, ["message_id": .int(7)])
        #expect(isError)
        #expect(text.contains("language"))
        #expect(fixture.engine.transcribeCount == 0)
        #expect(ToolCatalog.audioTranscribe.inputSchema.objectValue?["required"]?.arrayValue?
            .contains(.string("language")) == true)
    }

    @Test("A path outside Message/, a missing file and both-or-neither arguments are refused")
    func argumentsAreChecked() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        let outside = fixture.directory.appendingPathComponent("outside.wav")
        _ = try fixture.makeWAV(named: "outside.wav", in: fixture.directory)
        let inside = try fixture.makeWAV(named: "ok.wav")
        let tools = fixture.tools(converter: nil)

        let (escaped, escapedError) = await run(
            tools, ["path": .string(outside.path), "language": .string("en")])
        #expect(escapedError)
        #expect(escaped.contains("not a file inside WhatsApp's Message folder"))

        let (traversal, traversalError) = await run(
            tools, ["path": .string(fixture.media.path + "/../../outside.wav"), "language": .string("en")])
        #expect(traversalError, Comment(rawValue: traversal))

        let (missing, missingError) = await run(
            tools, ["path": .string(fixture.media.path + "/nope.wav"), "language": .string("en")])
        #expect(missingError, Comment(rawValue: missing))

        let (_, neitherError) = await run(tools, ["language": .string("en")])
        #expect(neitherError)
        let (_, bothError) = await run(
            tools, ["path": .string(inside.path), "message_id": .int(1), "language": .string("en")])
        #expect(bothError)

        let (ok, okError) = await run(tools, ["path": .string(inside.path), "language": .string("en")])
        #expect(!okError, Comment(rawValue: ok))
        #expect(ok.contains("invented words"))
    }

    @Test("A photo has no sound, and an evicted voice note is reported as not on this Mac")
    func wrongKindAndMissingFile() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        let photo = Fixtures.message(
            id: 8, chatID: 1, chatName: "Ane", text: nil,
            body: Fixtures.attachment(.photo, path: nil))
        let tools = fixture.tools(
            converter: nil, messages: [photo, fixture.voiceNote(id: 7, path: nil)])

        let (photoText, photoError) = await run(
            tools, ["message_id": .int(8), "language": .string("es")])
        #expect(photoError)
        #expect(photoText.contains("no sound to transcribe"))

        let (gone, goneError) = await run(tools, ["message_id": .int(7), "language": .string("es")])
        #expect(!goneError)
        #expect(gone.contains("not on this Mac"))
    }

    @Test("Silence is reported as silence, not as an empty success")
    func silenceIsReported() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        fixture.engine.segments = []
        let wav = try fixture.makeWAV(named: "quiet.wav")
        let tools = fixture.tools(converter: nil)
        let (text, isError) = await run(tools, ["path": .string(wav.path), "language": .string("en")])
        #expect(!isError)
        #expect(text.contains("No speech was recognised"))
    }

    @Test("The catalogue marks audio_transcribe as read-only, and says it never downloads")
    func annotationsAreHonest() {
        let tool = ToolCatalog.audioTranscribe
        #expect(tool.annotations.readOnlyHint == true)
        #expect(tool.annotations.destructiveHint == false)
        #expect(tool.annotations.openWorldHint == false)
        #expect(tool.description?.contains("no language model is ever downloaded") == true)
    }
}

/// Runs macOS's real on-device recogniser against speech synthesised by `say` from an
/// invented sentence. Off by default because it needs a speech model installed and takes
/// seconds: `WHATSAPP_MCP_SPEECH_TESTS=1 swift test --filter NativeSpeech`.
@Suite("ffmpeg input is pinned and playlists are refused")
struct FFmpegPinningTests {

    @Test("The container is recognised from its first bytes, whatever the file is called")
    func sniffing() {
        func demuxer(_ bytes: [UInt8]) -> String? { MediaFormat.ffmpegDemuxer(forHeader: bytes) }
        let ascii: (String) -> [UInt8] = { Array($0.utf8) }
        #expect(demuxer(ascii("OggS") + [0, 2]) == "ogg")
        #expect(demuxer(ascii("RIFF") + [0, 0, 0, 0] + ascii("WAVE")) == "wav")
        #expect(demuxer(ascii("RIFF") + [0, 0, 0, 0] + ascii("AVI ")) == nil)
        #expect(demuxer(ascii("FORM") + [0, 0, 0, 0] + ascii("AIFF")) == "aiff")
        #expect(demuxer(ascii("fLaC")) == "flac")
        #expect(demuxer(ascii("caff") + [0, 1]) == "caf")
        #expect(demuxer(ascii("FORM") + [0, 0, 0, 0] + ascii("AIFC")) == "aiff")
        #expect(demuxer([0x1A, 0x45, 0xDF, 0xA3]) == "matroska")
        #expect(demuxer([0, 0, 0, 0x1C] + ascii("ftypM4A ")) == "mov")
        #expect(demuxer([0, 0, 0, 8] + ascii("moov")) == "mov")
        #expect(demuxer(ascii("ID3") + [4, 0]) == "mp3")
        #expect(demuxer([0xFF, 0xFB, 0x90, 0x00]) == "mp3")
        #expect(demuxer([0xFF, 0xF1, 0x50, 0x80]) == "aac")
        #expect(demuxer(ascii("#!AMR\n")) == "amr")
        // What an attacker would save instead.
        for hostile in ["#EXTM3U\n#EXTINF:1,\nfile:///x", "ffconcat version 1.0\nfile 'x'", "v=0\no=- 0 0 IN IP4", "<html>", "", "abc"] {
            #expect(demuxer(ascii(hostile)) == nil, Comment(rawValue: hostile))
        }
    }

    private func run(_ file: String, contents: Data, converter: (TranscriptionFixtureShim) throws -> FFmpegConverter)
        async throws -> (result: Result<Transcription, any Error>, runs: [String])
    {
        let shim = try TranscriptionFixtureShim()
        defer { shim.remove() }
        let url = shim.media.appendingPathComponent(file)
        try contents.write(to: url)
        let service = TranscriptionService(
            mediaFiles: MediaFiles(root: shim.root), scratchDirectory: shim.cache,
            converter: try converter(shim), engine: shim.engine)
        let outcome: Result<Transcription, any Error>
        do { outcome = .success(try await service.transcribe(file: url, language: "es")) } catch {
            outcome = .failure(error)
        }
        return (outcome, shim.ffmpegRuns())
    }

    @Test("A playlist saved into Message/ is refused and ffmpeg is never started")
    func playlistIsRefused() async throws {
        for name in ["list.m3u8", "list.ffconcat", "list.sdp", "voice.opus"] {
            let playlist = Data("#EXTM3U\n#EXT-X-TARGETDURATION:3\n#EXTINF:2.0,\nfile:///etc/hosts\n#EXT-X-ENDLIST\n".utf8)
            let (outcome, runs) = try await run(name, contents: playlist) { try $0.fakeFFmpeg() }
            guard case .failure(let error) = outcome else {
                Issue.record("\(name) was transcribed"); continue
            }
            #expect(error as? TranscriptionError == .unsupportedFormat, Comment(rawValue: name))
            #expect(TranscriptionError.unsupportedFormat.message.contains("playlist"))
            #expect(runs.isEmpty, Comment(rawValue: "ffmpeg ran for \(name)"))
        }
    }

    @Test("ffmpeg is told the container with -f before -i, and reads one audio stream of one file")
    func argumentsArePinned() async throws {
        let (outcome, runs) = try await run("note.opus", contents: oggBytes("body")) { try $0.fakeFFmpeg() }
        guard case .success = outcome else { Issue.record("conversion failed: \(outcome)"); return }
        let line = try #require(runs.first)
        let words = line.split(separator: " ").map(String.init)
        let format = try #require(words.firstIndex(of: "-f"))
        let input = try #require(words.firstIndex(of: "-i"))
        #expect(words[format + 1] == "ogg")
        #expect(format < input, "the demuxer must be named before the input")
        #expect(words[input + 1].hasPrefix("file:/"))
        #expect(line.contains("-protocol_whitelist file"))
        #expect(line.contains("-map 0:a:0"))
        #expect(line.contains("-nostdin"))
    }

    @Test("The name of the file decides nothing: Ogg bytes under a .m3u8 name are Ogg")
    func contentWinsOverName() async throws {
        let (outcome, runs) = try await run("sneaky.m3u8", contents: oggBytes("body")) { try $0.fakeFFmpeg() }
        guard case .success = outcome else { Issue.record("\(outcome)"); return }
        #expect(runs.first?.contains("-f ogg") == true)
    }

    @Test("With the real ffmpeg, a Matroska clip macOS cannot open is converted; a playlist naming a real file is not",
          .enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg")))
    func realFFmpeg() async throws {
        let shim = try TranscriptionFixtureShim()
        defer { shim.remove() }
        let ffmpeg = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        let mka = shim.media.appendingPathComponent("tone.mka")
        let make = Process()
        make.executableURL = ffmpeg
        make.arguments = ["-loglevel", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=1", mka.path]
        try make.run(); make.waitUntilExit()
        #expect(make.terminationStatus == 0)

        // A real audio file OUTSIDE Message/, and a playlist inside it that names it.
        let outside = shim.directory.appendingPathComponent("outside.wav")
        let makeOutside = Process()
        makeOutside.executableURL = ffmpeg
        makeOutside.arguments = ["-loglevel", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=880:duration=1", outside.path]
        try makeOutside.run(); makeOutside.waitUntilExit()
        let playlist = shim.media.appendingPathComponent("evil.m3u8")
        try Data("#EXTM3U\n#EXT-X-TARGETDURATION:3\n#EXTINF:2.0,\nfile://\(outside.path)\n#EXT-X-ENDLIST\n".utf8).write(to: playlist)

        let service = TranscriptionService(
            mediaFiles: MediaFiles(root: shim.root), scratchDirectory: shim.cache,
            converter: FFmpegConverter(executable: ffmpeg), engine: shim.engine)

        let converted = try await service.transcribe(file: mka, language: "es")
        #expect(converted.durationSeconds > 0.9 && converted.durationSeconds < 1.1)
        #expect(shim.transcribeCount == 1)

        await #expect(throws: TranscriptionError.unsupportedFormat) {
            _ = try await service.transcribe(file: playlist, language: "es")
        }
        #expect(shim.transcribeCount == 1, "the playlist reached the engine")
    }
}

@Suite("Language resolution")
struct LanguageResolutionTests {
    private let supported = ["en-GB", "en-US", "es-CL", "es-ES", "es-MX", "es-US", "fr-FR", "pt-BR", "pt-PT"]
    private let installed = ["en-US", "es-ES", "es-US", "fr-FR", "pt-BR"]

    private func resolve(_ requested: String?) throws -> String {
        try NativeSpeechTranscriber.resolve(requested: requested, supported: supported, installed: installed)
    }

    @Test("A full tag resolves to exactly that model, however it is spelled")
    func fullTagsResolve() throws {
        #expect(try resolve("es-ES") == "es-ES")
        #expect(try resolve("es_es") == "es-ES")
        #expect(try resolve(" en-US ") == "en-US")
    }

    @Test("A bare language is accepted only when it names one model")
    func bareLanguage() throws {
        #expect(try resolve("fr") == "fr-FR")
        for ambiguous in ["es", "en"] {
            #expect(throws: TranscriptionError.self) { try resolve(ambiguous) }
        }
        do { _ = try resolve("es") } catch let error as TranscriptionError {
            #expect(error == .ambiguousLanguage(requested: "es", candidates: ["es-CL", "es-ES", "es-MX", "es-US"]))
        }
    }

    @Test("A region the engine lacks is never replaced by a neighbour")
    func noRegionalSubstitution() throws {
        #expect(throws: TranscriptionError.unsupportedLanguage(requested: "es-AR", supported: supported)) {
            try resolve("es-AR")
        }
    }

    @Test("Basque and Catalan are unsupported, and no language at all is an error")
    func unsupportedAndMissing() throws {
        for language in ["eu", "eu-ES", "ca", "ca-ES"] {
            #expect(throws: TranscriptionError.unsupportedLanguage(requested: language, supported: supported)) {
                try resolve(language)
            }
        }
        for blank in [nil, "", "   "] {
            #expect(throws: TranscriptionError.noLanguage(supported: supported)) { try resolve(blank) }
        }
    }

    @Test("A supported language with no model installed is reported, never downloaded")
    func notInstalled() throws {
        #expect(throws: TranscriptionError.modelNotInstalled("pt-PT")) { try resolve("pt-PT") }
    }
}

@Suite("NativeSpeech", .enabled(if: ProcessInfo.processInfo.environment["WHATSAPP_MCP_SPEECH_TESTS"] != nil))
struct NativeSpeechIntegrationTests {

    @Test("Synthesised English speech is recognised, with times, and Basque is refused")
    func recognisesSynthesisedSpeech() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        let url = fixture.media.appendingPathComponent("spoken.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, "The invented meeting is on Tuesday at five."]
        try say.run()
        say.waitUntilExit()
        #expect(say.terminationStatus == 0)

        let service = TranscriptionService(
            mediaFiles: MediaFiles(root: fixture.root), scratchDirectory: fixture.cache,
            converter: nil, engine: NativeSpeechTranscriber())
        let result = try await service.transcribe(file: url, language: "en-US")
        let text = result.segments.map(\.text).joined(separator: " ").lowercased()
        #expect(text.contains("tuesday"), Comment(rawValue: text))
        #expect(result.segments.allSatisfy { $0.end >= $0.start })

        await #expect(throws: TranscriptionError.self) {
            _ = try await service.transcribe(file: url, language: "eu")
        }
    }
}
