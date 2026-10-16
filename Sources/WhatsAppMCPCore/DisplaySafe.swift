import Foundation

extension String {
    /// This text as one line that cannot pass for the tool's own structure.
    ///
    /// Names, filenames, captions and "about" lines are written by other people, and the
    /// answers they appear in are read by a model. A name containing a line break could end
    /// its own line and begin another that looks like `Showing 1–50 of 3` or `NOTE: …`, and a
    /// right-to-left override can make text read in a different order than it is stored.
    /// Line breaks and tabs become spaces; other control characters, the bidirectional
    /// overrides and isolates, zero-width spaces and the byte-order mark are removed. Joiners
    /// (U+200C, U+200D) stay: emoji sequences and several scripts need them.
    var displaySafe: String {
        var result = String.UnicodeScalarView()
        for scalar in unicodeScalars {
            switch scalar.value {
            case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029:
                result.append(" ")
            case 0x00...0x1F, 0x7F...0x9F:
                continue
            case 0x200B, 0x202A...0x202E, 0x2066...0x2069, 0xFEFF:
                continue
            default:
                result.append(scalar)
            }
        }
        return String(result)
    }

    /// For a block of text that is shown on its own lines (a message body, a vCard): every
    /// line is prefixed, so no line of it can begin like one of the tool's own headers.
    /// Control characters other than the line break are removed as above.
    var quotedBlock: String {
        // "\r\n" is one break, not two.
        let lines = replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: CharacterSet(charactersIn: "\n\r\u{85}\u{2028}\u{2029}"))
        return lines.map { "  │ " + $0.displaySafe }.joined(separator: "\n")
    }
}
