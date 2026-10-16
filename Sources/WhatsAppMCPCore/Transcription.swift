import AVFoundation
import Foundation
import UniformTypeIdentifiers

public struct TranscriptSegment: Sendable, Equatable, Codable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct Transcription: Sendable, Equatable, Codable {
    public var localeIdentifier: String
    public var durationSeconds: Double
    public var segments: [TranscriptSegment]
    public var sha256: String
    /// Not stored: set when a result was read back instead of computed.
    public var fromCache = false

    enum CodingKeys: String, CodingKey {
        case localeIdentifier, durationSeconds, segments, sha256
    }
}

public enum TranscriptionError: Error, Equatable {
    case unsupportedLanguage(requested: String, supported: [String])
    case noLanguage(supported: [String])
    case ambiguousLanguage(requested: String, candidates: [String])
    case modelNotInstalled(String)
    case engineUnavailable(String)
    case converterMissing
    case conversionFailed(String)
    /// The file is not a plain audio or video container ffmpeg may be pointed at.
    case unsupportedFormat
    case unreadable(String)
    case tooLarge(Int64)

    public var message: String {
        switch self {
        case .unsupportedLanguage(let requested, let supported):
            return """
                The speech recognition built into this Mac has no model for '\(requested)'.

                It supports: \(supported.joined(separator: ", ")).

                This server does not substitute another language, because text recognised \
                in the wrong language is plausible-looking nonsense. Basque (eu) and Catalan \
                (ca) are not among the languages macOS offers for this engine.
                """

        case .noLanguage(let supported):
            return """
                No 'language' was given. macOS cannot detect it, and this server does not \
                assume this Mac's own language — a Spanish voice note recognised as English \
                is fluent nonsense. Pass the language the audio is spoken in, one of: \
                \(supported.joined(separator: ", ")).
                """

        case .ambiguousLanguage(let requested, let candidates):
            return """
                '\(requested)' names a language, not a regional model, and macOS has several: \
                \(candidates.joined(separator: ", ")). They differ in accent and vocabulary, so \
                this server will not pick one for you. Pass the full tag, for example \
                \(candidates.first ?? requested).
                """

        case .modelNotInstalled(let identifier):
            return """
                The speech model for \(identifier) is supported but not installed on this Mac. \
                This server never downloads one. Add the language under System Settings → \
                Keyboard → Dictation, let macOS fetch it, then try again.
                """

        case .engineUnavailable(let reason):
            return "The speech recognition built into macOS cannot be used here: \(reason)"

        case .converterMissing:
            return """
                macOS could not open this file on its own (a video's sound track and some containers \
                need a converter, and on older macOS versions so may Ogg Opus voice notes), \
                and ffmpeg was not found.

                Install it with `brew install ffmpeg`, or point this server at it with \
                `--ffmpeg /path/to/ffmpeg`. It runs locally, on this one file, with no network.
                """

        case .conversionFailed(let detail):
            return "ffmpeg could not convert the audio: \(detail)"

        case .unsupportedFormat:
            return """
                This file is not in an audio or video format this server will hand to ffmpeg.
                Only plain containers recognised by their first bytes are converted (Ogg,
                MP4/M4A/QuickTime, WAV, MP3, AAC, FLAC, AIFF, CAF, AMR, Matroska); a playlist
                or any other file is refused, because such a file can name other files for
                ffmpeg to read.
                """

        case .unreadable(let detail):
            return "The audio could not be read: \(detail)"

        case .tooLarge(let size):
            return "This file is \(size) bytes, over the \(TranscriptionService.maximumFileBytes)-byte limit for transcription."
        }
    }
}

/// The speech engine behind a seam, so the pipeline around it — conversion, caching,
/// cleanup — is tested without speech recognition running.
public protocol SpeechTranscribing: Sendable {
    /// The locale the engine will use for a request, or an error naming what it supports.
    func resolveLocale(_ requested: String?) async throws -> String
    func transcribe(audio: URL, locale: String) async throws -> [TranscriptSegment]
}

/// Turns anything ffmpeg can read into a 16 kHz mono WAV, in a directory this server owns.
public struct FFmpegConverter: Sendable {
    public let executable: URL
    public var timeout: TimeInterval = 120

    public init(executable: URL) {
        self.executable = executable
    }

    /// Where ffmpeg is when no path was given. Homebrew's two prefixes; nothing is searched
    /// on `PATH`, because an extension host's `PATH` is not the user's.
    public static func locate() -> URL? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public func convert(_ input: URL, to output: URL) async throws {
        // Decided here, before anything is started: `-f` names the demuxer so ffmpeg never
        // sniffs the content itself (see `MediaFormat`), and a file that is not a plain
        // container never reaches it.
        guard let demuxer = MediaFormat.ffmpegDemuxer(for: input) else {
            throw TranscriptionError.unsupportedFormat
        }
        let process = Process()
        process.executableURL = executable
        // `-f <demuxer>` before `-i` pins the format; `-protocol_whitelist file` keeps ffmpeg
        // to local files; `file:` makes the path a path even if it began with a dash;
        // `-nostdin` stops it waiting on a terminal that does not exist; `-map 0:a:0` and
        // `-vn` read the first audio stream only, so a clip is used for its sound.
        process.arguments = [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-protocol_whitelist", "file",
            "-f", demuxer, "-i", "file:" + input.path, "-map", "0:a:0", "-vn", "-ac", "1",
            "-ar", "16000", "-f", "wav", "-y", output.path,
        ]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        // Collected as it arrives instead of read to end-of-file afterwards: a wrapper script
        // whose child outlives it would keep the pipe open, and waiting for EOF would then
        // wait for as long as that child lives.
        let captured = CapturedOutput()
        errors.fileHandleForReading.readabilityHandler = { handle in
            captured.append(handle.availableData)
        }
        defer { errors.fileHandleForReading.readabilityHandler = nil }

        do { try process.run() } catch {
            throw TranscriptionError.conversionFailed(error.localizedDescription)
        }
        let running = RunningProcess(process)
        ProcessCleanup.shared.register(child: process)
        defer { ProcessCleanup.shared.unregister(child: process) }

        // Cancelling the request must stop ffmpeg: the scratch directory is deleted when
        // this call unwinds, and a process still writing into it would be left behind.
        try await withTaskCancellationHandler {
            let deadline = Date().addingTimeInterval(timeout)
            while running.isRunning {
                if Date() > deadline {
                    running.kill()
                    throw TranscriptionError.conversionFailed(
                        "it ran past \(Int(timeout)) seconds and was stopped")
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        } onCancel: {
            running.kill()
        }

        let detail = String(decoding: captured.snapshot().prefix(400), as: UTF8.self)
        guard running.terminationStatus == 0 else {
            throw TranscriptionError.conversionFailed(
                detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "exit status \(running.terminationStatus)" : detail)
        }
    }
}

/// Bytes from a pipe, appended from the readability handler's queue and read from the task.
private final class CapturedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
    func snapshot() -> Data { lock.withLock { data } }
}

/// A `Process` shared between the waiting task and a cancellation handler.
private final class RunningProcess: @unchecked Sendable {
    private let process: Process

    init(_ process: Process) { self.process = process }

    var isRunning: Bool { process.isRunning }
    var terminationStatus: Int32 { process.terminationStatus }

    /// SIGTERM, then SIGKILL after two seconds, because a process that ignores the first
    /// would otherwise run on after the call has returned.
    func kill() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
            if process.isRunning { Foundation.kill(pid, SIGKILL) }
        }
    }
}

/// Transcribes one file: convert if macOS cannot open it, recognise on this Mac, remember.
///
/// Everything it writes is under `cacheDirectory`: a scratch directory for the converted
/// WAV, deleted when the call ends, and `transcripts/`, which keeps each result keyed by the
/// file's SHA-256 and the language so the same audio is never recognised twice. A cached
/// transcript is the content of someone's message in plaintext, so the directories are
/// `0700` and the files `0600`.
public struct TranscriptionService: Sendable {
    public let mediaFiles: MediaFiles
    public let cacheDirectory: URL
    public let converter: FFmpegConverter?
    public let engine: any SpeechTranscribing

    public static let maximumFileBytes: Int64 = 200 * 1024 * 1024

    public init(
        mediaFiles: MediaFiles, cacheDirectory: URL, converter: FFmpegConverter?,
        engine: any SpeechTranscribing
    ) {
        self.mediaFiles = mediaFiles
        self.cacheDirectory = cacheDirectory
        self.converter = converter
        self.engine = engine
    }

    public func transcribe(file url: URL, language: String?) async throws -> Transcription {
        let size =
            (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
        guard size <= Self.maximumFileBytes else { throw TranscriptionError.tooLarge(size) }

        let trimmed = language?.trimmingCharacters(in: .whitespacesAndNewlines)
        let locale = try await engine.resolveLocale(trimmed?.isEmpty == true ? nil : trimmed)
        let facts = try MediaFiles.facts(of: url)
        let cached = cacheURL(sha256: facts.sha256, locale: locale)
        if let data = try? Data(contentsOf: cached),
            var stored = try? JSONDecoder().decode(Transcription.self, from: data)
        {
            stored.fromCache = true
            return stored
        }

        let scratch = cacheDirectory.appendingPathComponent("tmp/\(UUID().uuidString)")
        try makePrivateDirectory(scratch)
        ProcessCleanup.shared.register(path: scratch.path)
        defer {
            ProcessCleanup.shared.unregister(path: scratch.path)
            try? FileManager.default.removeItem(at: scratch)
        }

        let (audio, duration) = try await readableAudio(from: url, scratch: scratch)
        let segments = try await engine.transcribe(audio: audio, locale: locale)
        let result = Transcription(
            localeIdentifier: locale, durationSeconds: duration, segments: segments,
            sha256: facts.sha256)
        try store(result, at: cached)
        return result
    }

    /// A file AVFoundation can read: the original if it already is one, otherwise ffmpeg's
    /// WAV. Video always goes through ffmpeg so its sound track is what is read.
    private func readableAudio(from url: URL, scratch: URL) async throws -> (URL, Double) {
        let isVideo = (UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .movie)) == true
        if !isVideo, let file = try? AVAudioFile(forReading: url) {
            return (url, Double(file.length) / file.processingFormat.sampleRate)
        }
        guard let converter else { throw TranscriptionError.converterMissing }
        let wav = scratch.appendingPathComponent("audio.wav")
        try await converter.convert(url, to: wav)
        guard let file = try? AVAudioFile(forReading: wav), file.length > 0 else {
            throw TranscriptionError.conversionFailed("the converted file is empty or unreadable")
        }
        return (wav, Double(file.length) / file.processingFormat.sampleRate)
    }

    private var transcriptsDirectory: URL { cacheDirectory.appendingPathComponent("transcripts") }

    func cacheURL(sha256: String, locale: String) -> URL {
        let safeLocale = locale.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        return transcriptsDirectory.appendingPathComponent("\(sha256)-\(safeLocale).json")
    }

    private func store(_ transcription: Transcription, at url: URL) throws {
        try makePrivateDirectory(transcriptsDirectory)
        try PrivateFile.write(try JSONEncoder().encode(transcription), to: url)
    }

    private func makePrivateDirectory(_ url: URL) throws {
        try PrivateDirectory.ensure(url)
    }
}
