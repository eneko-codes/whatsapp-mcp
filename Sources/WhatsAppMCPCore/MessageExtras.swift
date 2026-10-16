import Foundation

/// One emoji reaction on a message.
public struct Reaction: Sendable, Equatable {
    public let emoji: String
    /// Who reacted. Nil when the entry WhatsApp stored names nobody: every reaction seen
    /// from another person carries their address, and the entries without one sit on
    /// messages from other people. They are probably the owner's own reactions, but that is
    /// not established, so it is reported as "not recorded" and never as "you".
    public let reactor: Identity?
    public let date: Date?

    public init(emoji: String, reactor: Identity?, date: Date?) {
        self.emoji = emoji.displaySafe
        self.reactor = reactor
        self.date = date
    }
}

/// The message another message replies to.
public struct Quote: Sendable, Equatable {
    /// WhatsApp's own id of the quoted message (`ZWAMESSAGE.ZSTANZAID`), not a row id.
    public let stanzaID: String
    /// `Z_PK` of the quoted message in this chat, when it is on this Mac. Nil is ordinary:
    /// WhatsApp keeps the quote's text inside the reply, so the original may be gone.
    public let localMessageID: Int64?
    /// True/false once the quoted message is found locally; nil when it is not.
    public let quotedIsFromMe: Bool?
    /// The address WhatsApp stored for the quoted message's author, when it stored one.
    public let author: Identity?
    /// The words of the quoted message as WhatsApp copied them into the reply. Nil when the
    /// quote carries none (a quoted photo, say).
    public let text: String?

    public init(
        stanzaID: String, localMessageID: Int64? = nil, quotedIsFromMe: Bool? = nil,
        author: Identity? = nil, text: String? = nil
    ) {
        self.stanzaID = stanzaID
        self.localMessageID = localMessageID
        self.quotedIsFromMe = quotedIsFromMe
        self.author = author
        self.text = text?.displaySafe
    }
}

/// Reads reactions out of `ZWAMESSAGEINFO.ZRECEIPTINFO` and a quote out of
/// `ZWAMEDIAITEM.ZMETADATA`.
///
/// Both are protocol-buffers blobs with no published schema. The field numbers below were
/// read off this Mac's own store by decoding blobs whose meaning was known (a reaction the
/// owner could see in WhatsApp, a reply whose original was found by the id inside it), and
/// every number is a place where a WhatsApp update could silently change the answer — so
/// an unrecognised shape yields nothing, never a guess.
enum MessageExtras {

    /// `ZRECEIPTINFO` is a list of per-device receipts (fields 1 and 2) with reactions in
    /// repeated field 7. Each reaction is wrapped one level down in one of two shapes:
    ///
    /// - field 1: `{1: reaction id, 2: reactor address, 3: emoji, 4: time in ms}`
    /// - field 2: `{1: reaction id, 2: emoji, 3: time in ms}`, with no address
    static func reactions(in receipt: Data?, resolve: (String) -> Identity) -> [Reaction] {
        guard let receipt else { return [] }
        var found: [Reaction] = []
        for entry in ProtobufWire.fields(receipt) where entry.number == 7 {
            guard let wrapped = entry.bytes else { continue }
            for shape in ProtobufWire.fields(wrapped) {
                guard let body = shape.bytes else { continue }
                let fields = ProtobufWire.fields(body)
                func string(_ number: Int) -> String? {
                    fields.first { $0.number == number }?.string
                }
                func integer(_ number: Int) -> UInt64? {
                    fields.first { $0.number == number }?.integer
                }
                let reactor: String?
                let emoji: String?
                let milliseconds: UInt64?
                switch shape.number {
                case 1:
                    reactor = string(2)
                    emoji = string(3)
                    milliseconds = integer(4)
                case 2:
                    reactor = nil
                    emoji = string(2)
                    milliseconds = integer(3)
                default:
                    continue
                }
                guard let emoji, isReactionEmoji(emoji) else { continue }
                found.append(
                    Reaction(
                        emoji: emoji,
                        reactor: reactor.flatMap { $0.contains("@") ? resolve($0) : nil },
                        date: milliseconds.flatMap(date(milliseconds:))))
            }
        }
        return found.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }

    /// A reaction is a short run of emoji. Anything else in that slot is a different kind of
    /// entry and is skipped rather than shown as a reaction.
    private static func isReactionEmoji(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= 32 else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            scalar.value > 0x7F || scalar.properties.isEmoji
        } && text.unicodeScalars.contains { $0.value > 0x7F }
    }

    /// Unix milliseconds. Outside 2009 to a day from now the number is not a time.
    private static func date(milliseconds: UInt64) -> Date? {
        let seconds = Double(milliseconds) / 1000
        guard seconds > 1_230_000_000, seconds < Date().timeIntervalSince1970 + 86_400 else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }

    struct RawQuote: Equatable {
        let stanzaID: String
        let participant: String?
        let text: String?
    }

    /// `ZMETADATA` of a reply: field 5 is the quoted message's id, field 6 its author's
    /// address, field 19 a message whose field 1 is the quoted text.
    static func quote(in metadata: Data?) -> RawQuote? {
        guard let metadata else { return nil }
        let fields = ProtobufWire.fields(metadata)
        guard let stanza = fields.first(where: { $0.number == 5 })?.string,
            isStanzaID(stanza)
        else { return nil }
        let participant = fields.first { $0.number == 6 }?.string
        let text = fields.first { $0.number == 19 }?.bytes
            .flatMap { ProtobufWire.fields($0).first { $0.number == 1 }?.string }
        return RawQuote(
            stanzaID: stanza,
            participant: participant.flatMap { $0.contains("@") ? $0 : nil },
            text: text.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// WhatsApp's message ids are 10 to 64 letters and digits. The check is what keeps a
    /// field 5 on a different kind of metadata from being read as a quote.
    private static func isStanzaID(_ text: String) -> Bool {
        (10...64).contains(text.utf8.count)
            && text.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
            }
    }
}
