import Foundation

/// Which container a file really is, from its first bytes and nothing else.
///
/// ffmpeg picks a demuxer by sniffing, and some demuxers are not about audio at all: a
/// playlist (`.m3u8`, `.ffconcat`, `.sdp`) is a list of *other* inputs, and with
/// `-protocol_whitelist file` it still reads any local file it names. A hostile contact can
/// get such a file saved into `Message/`, so ffmpeg is never left to choose: this decides
/// the format, ffmpeg is told with `-f`, and anything that is not a plain audio or video
/// container is refused before ffmpeg starts.
enum MediaFormat {

    /// The ffmpeg demuxer name for a recognised container, or nil.
    static func ffmpegDemuxer(for url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 16), head.count >= 4 else { return nil }
        return ffmpegDemuxer(forHeader: [UInt8](head))
    }

    static func ffmpegDemuxer(forHeader bytes: [UInt8]) -> String? {
        func starts(with text: String, at offset: Int = 0) -> Bool {
            let expected = Array(text.utf8)
            return bytes.count >= offset + expected.count
                && Array(bytes[offset..<offset + expected.count]) == expected
        }
        if starts(with: "OggS") { return "ogg" }
        if starts(with: "RIFF"), starts(with: "WAVE", at: 8) { return "wav" }
        if starts(with: "FORM"), starts(with: "AIFF", at: 8) || starts(with: "AIFC", at: 8) {
            return "aiff"
        }
        if starts(with: "fLaC") { return "flac" }
        if starts(with: "caff") { return "caf" }
        if starts(with: "#!AMR") { return "amr" }
        if bytes.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { return "matroska" }
        // MP4, M4A, 3GP and QuickTime all put a box type at offset 4.
        for box in ["ftyp", "moov", "mdat", "wide", "free", "skip"] where starts(with: box, at: 4) {
            return "mov"
        }
        if starts(with: "ID3") { return "mp3" }
        // A bare MPEG audio frame: eleven set bits. The layer bits tell ADTS AAC (00) from MP3.
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] & 0xE0 == 0xE0 {
            return bytes[1] & 0x06 == 0 ? "aac" : "mp3"
        }
        return nil
    }
}
