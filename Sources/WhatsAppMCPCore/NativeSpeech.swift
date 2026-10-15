import AVFoundation
import Foundation
import Speech

/// macOS's own on-device speech recognition (`SpeechAnalyzer` / `SpeechTranscriber`, macOS
/// 26 and later). No audio and no text leaves this Mac: the engine has no server path, and
/// this type never asks for a model to be downloaded — a locale that is supported but not
/// installed is reported, not fetched.
///
/// It also never falls back to another language. Recognising Basque speech with a Spanish
/// model produces fluent, wrong text, which is worse than an error.
public struct NativeSpeechTranscriber: SpeechTranscribing {

    public init() {}

    public func resolveLocale(_ requested: String?) async throws -> String {
        guard #available(macOS 26, *) else {
            throw TranscriptionError.engineUnavailable(
                "on-device transcription needs macOS 26 or later")
        }
        return try Self.resolve(
            requested: requested,
            supported: await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) },
            installed: await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
    }

    /// Which model a request names, decided from the lists alone so it can be tested without
    /// the engine. Never substitutes: a region the engine lacks is an error, not the nearest
    /// one, and a bare language with several regional models is an error, not the first.
    /// (`SpeechTranscriber.supportedLocale(equivalentTo:)` does substitute — it maps `es` to
    /// es-US and `en` to en-GB — which is why it is not used.)
    static func resolve(requested: String?, supported: [String], installed: [String]) throws
        -> String
    {
        let names = supported.sorted()
        guard let raw = requested?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { throw TranscriptionError.noLanguage(supported: names) }

        let normalised = raw.replacingOccurrences(of: "_", with: "-")
        let parts = normalised.split(separator: "-").map(String.init)
        let language = parts.first?.lowercased() ?? ""
        let region = parts.count >= 2 ? parts.last?.uppercased() : nil

        let candidates = names.filter { $0.split(separator: "-").first?.lowercased() == language }
        guard !candidates.isEmpty else {
            throw TranscriptionError.unsupportedLanguage(requested: raw, supported: names)
        }

        let chosen: String
        if let region {
            guard let exact = candidates.first(where: { $0.uppercased().hasSuffix("-" + region) })
            else {
                throw TranscriptionError.unsupportedLanguage(requested: raw, supported: names)
            }
            chosen = exact
        } else if candidates.count == 1 {
            chosen = candidates[0]
        } else {
            throw TranscriptionError.ambiguousLanguage(requested: raw, candidates: candidates)
        }
        guard installed.contains(chosen) else { throw TranscriptionError.modelNotInstalled(chosen) }
        return chosen
    }

    public func transcribe(audio: URL, locale identifier: String) async throws -> [TranscriptSegment] {
        guard #available(macOS 26, *) else {
            throw TranscriptionError.engineUnavailable(
                "on-device transcription needs macOS 26 or later")
        }
        let transcriber = SpeechTranscriber(
            locale: Locale(identifier: identifier), transcriptionOptions: [],
            reportingOptions: [], attributeOptions: [.audioTimeRange])
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: audio) } catch {
            throw TranscriptionError.unreadable(error.localizedDescription)
        }

        // Results arrive on a stream that has to be consumed while the analyzer runs.
        let collector = Task { () -> [TranscriptSegment] in
            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                // A time that is not a number cannot be encoded to the cache or read by a person.
                let start = result.range.start.seconds
                let end = result.range.end.seconds
                segments.append(
                    TranscriptSegment(
                        start: start.isFinite ? start : 0, end: end.isFinite ? end : 0, text: text))
            }
            return segments
        }
        do {
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            return try await collector.value
        } catch is CancellationError {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw CancellationError()
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw TranscriptionError.engineUnavailable(error.localizedDescription)
        }
    }
}
