import Foundation

/// The `ZMESSAGETYPE` values this server knows by name.
///
/// WhatsApp documents none of them. Each was checked against this Mac's store by joining
/// to `ZWAMEDIAITEM` and looking at the *extension* of the stored file — never its
/// contents: type 1 stores `.jpg`, 2 and 11 `.mp4`, 3 `.opus`, 8 `.pdf`, 15 `.webp`; type
/// 5 is the only one whose media item carries a real position, and type 4 the only one
/// that is a vCard with no file.
///
/// Codes outside this list are deliberately not forced into the nearest name. WhatsApp
/// adds types with every feature — the measured library carries 28, 43, 46, 59, 63, 66,
/// 75, 76 and 79 among others — and a row reported as `type 59` is honest, where a row
/// reported as "text" would be a lie the reader cannot detect.
public enum MessageTypeCode {
    public static let text = 0
    public static let image = 1
    public static let video = 2
    public static let audio = 3
    public static let contact = 4
    public static let location = 5
    public static let groupEvent = 6
    public static let link = 7
    public static let document = 8
    /// The second code that carries a group event. Both 6 and 10 do; nothing distinguishes
    /// them that has been established by measurement.
    public static let groupEventAlternate = 10
    public static let gif = 11
    /// Deleted for everyone. See `MessageBody.deletedForEveryone` for what is and is not
    /// recoverable — the short answer is nothing.
    public static let deletedForEveryone = 14
    public static let sticker = 15

    /// The two codes that route into `MessageBody.groupEvent`. Not every message with a
    /// non-null `ZGROUPEVENTTYPE` is one: that column is set on 20,017 plain text messages
    /// in the measured library, so the **type** is the gate, never the column's presence.
    public static let groupEventCodes: Set<Int> = [groupEvent, groupEventAlternate]
}

/// What kind of conversation a row in `ZWACHATSESSION` describes.
///
/// The raw column is `ZSESSIONTYPE`. The mapping below was read off this Mac's own store
/// by correlating the code with the JID domain, which is self-describing: `@g.us` is a
/// group, `@broadcast` a broadcast list, `@status` a status feed, and `@s.whatsapp.net` /
/// `@lid` a person. `ChatKindTests` pins both the codes and that correlation, so a
/// WhatsApp update that renumbers them fails the suite instead of quietly relabelling
/// every chat.
public enum ChatKind: String, Sendable, Equatable, CaseIterable {
    case individual
    case group
    case broadcast
    case status
    case unknown

    public init(sessionTypeCode: Int) {
        switch sessionTypeCode {
        case 0: self = .individual
        case 1: self = .group
        case 2: self = .broadcast
        case 3: self = .status
        default: self = .unknown
        }
    }
}

// MARK: - Identity

/// What a JID's domain says about the party behind it.
///
/// The domain is the only self-describing part of a WhatsApp address, and it decides what
/// can be said about the party at all: a `@s.whatsapp.net` prefix is a phone number, and a
/// `@lid` prefix is an internal id that this database offers no way to turn into one.
public enum IdentityKind: String, Sendable, Equatable {
    case phone
    case lid
    case group
    case broadcast
    case other

    public init(jid: String) {
        switch jid.split(separator: "@").last.map(String.init) {
        case "s.whatsapp.net": self = .phone
        case "lid": self = .lid
        case "g.us": self = .group
        case "broadcast": self = .broadcast
        default: self = .other
        }
    }
}

/// One party — a sender, a group's creator, a mention's target — with everything this
/// database can say about them in one value.
///
/// There is no `phoneNumber` field for a `.lid` identity and there cannot be one: the
/// schema has no LID→phone mapping anywhere. Naming that absence in the type is the point,
/// because the alternative is a field that is nil for a reason nobody can see.
public struct Identity: Sendable, Equatable {
    public let jid: String
    /// Resolved through `JIDDisplay`: a profile name, else a `+<digits>` phone number, else
    /// the JID unchanged. Never empty.
    public let displayName: String
    public let kind: IdentityKind
    /// Absolute path to this party's profile picture, and only when the file is genuinely
    /// on this Mac. See `SystemWhatsAppStore.profilePicturePaths` for why the stored column
    /// cannot simply be handed over.
    public let profilePicturePath: String?

    public init(jid: String, displayName: String, profilePicturePath: String? = nil) {
        self.jid = jid
        self.displayName = displayName
        self.kind = IdentityKind(jid: jid)
        self.profilePicturePath = profilePicturePath
    }
}

// MARK: - Chats

/// There is deliberately no `disappearingMessagesTTL` or similar field here. Every table
/// and column name in the schema was checked for anything resembling an expiration or
/// ephemeral-message setting, on both `ZWACHATSESSION` and `ZWAMESSAGE`, and none exists
/// under any recognisable name in this WhatsApp version. `ZWACHATSESSION.ZFLAGS` is an
/// undecoded bitfield that could theoretically encode it, but decoding a bitfield by
/// guessing which bit means what is exactly the kind of unearned claim this server refuses
/// to make. This server has no way to tell "this message disappeared on schedule" from
/// "somebody deleted it".
public struct Chat: Sendable, Equatable {
    /// `ZWACHATSESSION.Z_PK`. A local row id: stable while the store is, meaningless
    /// anywhere else, and regenerated if WhatsApp is reinstalled.
    public let id: Int64
    /// The WhatsApp address, e.g. `34600123456@s.whatsapp.net` or `…@g.us`.
    public let jid: String
    public let name: String
    public let kind: ChatKind
    public let isArchived: Bool
    /// `ZHIDDEN`, set on 12 of 59 chats in the measured library. What WhatsApp's own UI
    /// calls this is not established, so the flag is reported and no verb is attached to
    /// it. Nil when the column is absent from this WhatsApp version.
    public let isHidden: Bool?
    public let unreadCount: Int
    public let messageCount: Int
    public let lastMessageDate: Date?
    public let lastMessageText: String?
    /// WhatsApp pins a chat by writing a date thousands of years in the future into
    /// `ZLASTMESSAGEDATE`, so that its own `ORDER BY … DESC` floats it to the top. There is
    /// no pin column to read: the inflated sort key is the only evidence there is.
    public let isPinned: Bool

    public init(
        id: Int64, jid: String, name: String, kind: ChatKind, isArchived: Bool,
        isHidden: Bool? = nil, unreadCount: Int, messageCount: Int, lastMessageDate: Date?,
        lastMessageText: String?, isPinned: Bool = false
    ) {
        self.id = id
        self.jid = jid
        self.name = name
        self.kind = kind
        self.isArchived = isArchived
        self.isHidden = isHidden
        self.unreadCount = unreadCount
        self.messageCount = messageCount
        self.lastMessageDate = lastMessageDate
        self.lastMessageText = lastMessageText
        self.isPinned = isPinned
    }
}

// MARK: - Attachments

/// What kind of file came with a message.
///
/// **`voiceNote` and `audioFile` are the same `ZMESSAGETYPE`.** Both are type 3, and the
/// only thing separating a thing somebody recorded from a file they attached is
/// `ZWAMEDIAITEM.ZMEDIAORIGIN`: origin 1 on 51 of the measured library's 52 type-3 rows,
/// every one of them storing `.opus`, and origin 0 on the single remaining one. Reported
/// as one undifferentiated "audio" the distinction is simply lost, and it is the
/// distinction a reader of a conversation cares about most.
public enum AttachmentKind: String, Sendable, Equatable, CaseIterable {
    case photo
    case video
    case gif
    case sticker
    case voiceNote
    case audioFile
    case document

    /// Nil when the type is not an attachment at all — a location, a contact card, a group
    /// event, plain text, or a code this server has never seen.
    ///
    /// `mediaOrigin` is only consulted for type 3, where it is the whole of the answer.
    public init?(typeCode: Int, mediaOrigin: Int?) {
        switch typeCode {
        case MessageTypeCode.image: self = .photo
        case MessageTypeCode.video: self = .video
        case MessageTypeCode.gif: self = .gif
        case MessageTypeCode.sticker: self = .sticker
        case MessageTypeCode.document: self = .document
        case MessageTypeCode.audio: self = mediaOrigin == 1 ? .voiceNote : .audioFile
        default: return nil
        }
    }

    /// Whether `ZWAMEDIAITEM.ZMOVIEDURATION` is a length in seconds for this kind.
    ///
    /// **On a document it is not.** The measured library's 119 documents carry values from
    /// 0 to 472 there, with 1, 2, 3 and 4 by far the commonest — a page count, on files
    /// whose names end in `.pdf`. Read as seconds it renders a contract as a two-second
    /// clip, which is wrong in a way a reader cannot detect. What the number counts is not
    /// established, so it is not surfaced under another name either. Photos and stickers
    /// store a flat zero and are excluded for tidiness rather than safety.
    public var hasDuration: Bool {
        switch self {
        case .video, .gif, .voiceNote, .audioFile: return true
        case .photo, .sticker, .document: return false
        }
    }

    /// What a reader sees. Distinct from `rawValue`, which is the filter argument's
    /// spelling.
    public var label: String {
        switch self {
        case .photo: return "photo"
        case .video: return "video"
        case .gif: return "gif"
        case .sticker: return "sticker"
        case .voiceNote: return "voice note"
        case .audioFile: return "audio"
        case .document: return "document"
        }
    }
}

/// A file WhatsApp attached to a message, whether or not it is still on this Mac.
public struct Attachment: Sendable, Equatable {
    public let kind: AttachmentKind
    /// Absolute path, and only when the file is genuinely on disk. WhatsApp keeps the row
    /// long after evicting the file — most rows have no usable path — so an absent path is
    /// the normal case and means "not on this Mac", never "the message is gone".
    public let localPath: String?
    public let fileSize: Int64?
    /// Seconds, for audio and video. Zero is stored for anything untimed and is reported
    /// as absent rather than as a zero-second clip.
    public let duration: Int?
    /// `ZTITLE` — a document's filename, mostly.
    public let title: String?
    /// `ZAUTHORNAME`. Populated on 119 rows in the measured library, **all of them
    /// documents**, so this is a document's author and nothing else.
    public let author: String?
    /// `ZMEDIAURL`, WhatsApp's own server URL for the file. Surfaced only when it really is
    /// a URL: 5357 of the 5359 populated rows begin with `http`, and the two that do not
    /// are not links to anything. This server never fetches it.
    public let remoteURL: String?

    public init(
        kind: AttachmentKind, localPath: String?, fileSize: Int64?, duration: Int?,
        title: String?, author: String? = nil, remoteURL: String? = nil
    ) {
        self.kind = kind
        self.localPath = localPath
        self.fileSize = fileSize
        self.duration = duration
        self.title = title
        self.author = author
        self.remoteURL = remoteURL
    }
}

/// The kinds `media_list` filters by: every attachment, plus the two message kinds whose
/// whole content is a media row rather than a file.
///
/// A location and a contact card are not attachments — nothing is downloaded and there is
/// no file to open — but they are what somebody *shared*, which is the question that tool
/// answers. Leaving them out would mean a caller looking for "everything shared in this
/// chat" has to know to run a different tool for two of the kinds.
/// The raw value is the spelling a caller passes in `kinds`, which is why two of them
/// differ from the case name: the argument is wire format, not Swift.
public enum MediaKind: String, Sendable, Equatable, CaseIterable {
    case photo
    case video
    case gif
    case sticker
    case voiceNote = "voice_note"
    case audioFile = "audio"
    case document
    case location
    case contactCard = "contact"

    public init(_ attachment: AttachmentKind) {
        switch attachment {
        case .photo: self = .photo
        case .video: self = .video
        case .gif: self = .gif
        case .sticker: self = .sticker
        case .voiceNote: self = .voiceNote
        case .audioFile: self = .audioFile
        case .document: self = .document
        }
    }
}

// MARK: - Message bodies

/// A shared location, exactly as WhatsApp stored it. No reverse geocoding: that would be a
/// network call this server does not make, and a guessed place name would be a claim the
/// database never made.
///
/// **`ZWAMEDIAITEM.ZLATITUDE` and `ZLONGITUDE` are only coordinates on `ZMESSAGETYPE` 5.**
/// Core Data reuses the same two columns for a picture's pixel dimensions on every other
/// media type: measured on the library, type 1 spans 132–4160 by 156–4032, and 2019 of the
/// 2039 non-zero rows are these dimensions rather than a position. Read without the type
/// gate, a photo comes back as a place at latitude 3024 — which is not merely wrong, it is
/// wrong in a way a reader cannot detect from the output. The 20 genuine type-5 rows all
/// fall inside valid ranges.
public struct Coordinates: Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Nil unless this really is a location message with a real position on it. The type
    /// gate is the important half; the 0/0 and range checks only catch a location row
    /// WhatsApp never filled in.
    public init?(latitude: Double?, longitude: Double?, typeCode: Int) {
        guard typeCode == MessageTypeCode.location,
            let latitude, let longitude,
            latitude != 0 || longitude != 0,
            (-90...90).contains(latitude), (-180...180).contains(longitude)
        else { return nil }
        self.latitude = latitude
        self.longitude = longitude
    }

    public var description: String {
        "\(String(format: "%.6f", latitude)), \(String(format: "%.6f", longitude))"
    }
}

/// A contact somebody shared, which is a vCard and no file.
///
/// **Both fields are gated on `ZMESSAGETYPE` 4**, and neither is optional about it.
/// `ZVCARDNAME` holds a 44-character base64 key on 4879 rows of every other type, and
/// `ZVCARDSTRING` is populated on 4875 rows that are stickers, photos, videos, documents,
/// audio and GIFs — none of them a vCard. Ungated, this server would report thousands of
/// shared contacts that were never shared.
public struct ContactCard: Sendable, Equatable {
    public let name: String?
    /// The raw vCard text, exactly as WhatsApp stored it. Not parsed here: a vCard's fields
    /// are a format this server would have to reimplement, and the text is what the caller
    /// can read for itself.
    public let vcard: String?

    /// Nil for anything that is not a shared contact. A type-4 message with neither field
    /// populated is still a shared contact — an empty card is a record of one, where
    /// falling through to "some unknown type 4" would not be.
    public init?(name: String?, vcard: String?, typeCode: Int) {
        guard typeCode == MessageTypeCode.contact else { return nil }
        self.name = name
        self.vcard = vcard
    }
}

/// The preview card WhatsApp built for a link somebody sent, read from
/// `ZWAMESSAGEDATAITEM`.
///
/// **That table holds up to 12 rows for a single message** — one per link in it — so it is
/// joined on `ZINDEX = 0` rather than on the message alone. Joined without that, a message
/// with several links comes back a dozen times and every count above it is wrong. The
/// measured library has exactly one `ZINDEX = 0` row per message it covers, on all 703.
public struct LinkPreview: Sendable, Equatable {
    /// `ZCONTENT1`, which is a URL on 715 of the 717 rows. `ZMATCHEDTEXT` holds the same
    /// value on the same rows, so only one is read.
    public let url: String?
    public let title: String?
    public let summary: String?

    public init(url: String?, title: String?, summary: String?) {
        self.url = url
        self.title = title
        self.summary = summary
    }

    public var isEmpty: Bool { url == nil && title == nil && summary == nil }
}

/// Somebody joined, left, was added, was removed, or the group's name changed.
///
/// `ZGROUPEVENTTYPE`'s codes are **not** mapped to verbs. They appear on plain text
/// messages too, so guessing a verb from the data alone risks a wrong one, and a wrong
/// "X removed Y" is worse evidence than an honestly unnamed code. The code is surfaced as
/// it is until that mapping is established by hand against the WhatsApp UI.
public struct GroupEvent: Sendable, Equatable {
    public let code: Int?
    /// `ZFROMJID`: who did it.
    public let actor: Identity
    /// `ZTEXT`, when it holds a JID — on a group event that column is not message text.
    ///
    /// Nil on most group events, and that is simply the truth of the data: only 57 of 202
    /// type-6/10 rows in the measured library carry a JID here at all, and there is no
    /// second source to fall back on. `ZWAGROUPMEMBERSCHANGE` looks like one and is not —
    /// it was implemented, measured at a 0/145 hit rate, and deleted.
    public let subject: Identity?

    public init(code: Int?, actor: Identity, subject: Identity?) {
        self.code = code
        self.actor = actor
        self.subject = subject
    }
}

/// What a message *is*, as one closed choice rather than a row of optional fields that
/// happen to be populated together.
///
/// The classification happens once, in `SystemWhatsAppStore`, against the type gates each
/// case documents. Everything above reads the case rather than re-deriving it, which is
/// what stops one tool from calling a row a photo while another calls it a location.
public enum MessageBody: Sendable, Equatable {
    /// Words and nothing else.
    case text
    case attachment(Attachment)
    case location(Coordinates)
    case contactCard(ContactCard)
    /// A link, with whatever preview WhatsApp built for it. The preview may be empty: a
    /// type-7 message with no `ZWAMESSAGEDATAITEM` row is still a link, and its URL is in
    /// the message text.
    case link(LinkPreview)
    case groupEvent(GroupEvent)
    /// `ZMESSAGETYPE` 14. **The text is not recoverable and the original row is not even
    /// identifiable.** Measured on 226 such rows: 220 have no `ZTEXT` at all, the 6 that do
    /// hold a JID rather than a stanza id, and none matches any `ZSTANZAID` anywhere.
    /// `ZPARENTMESSAGE` is NULL on all 27138 rows in the database. What survives is that a
    /// message was here, who sent it and when — nothing else, ever.
    case deletedForEveryone
    /// A `ZMESSAGETYPE` this server has no name for. Reported with its code rather than
    /// forced into the nearest case it resembles.
    case other(typeCode: Int)
}

/// `ZMESSAGESTATUS` and `ZMESSAGEERRORSTATUS`, raw.
///
/// **No code here is given a name.** The measured library holds 10 distinct status values
/// and they do not partition by direction the way "sent / delivered / read" would: 6 is the
/// commonest code both incoming (12417) and outgoing (8302), and 8 appears on both sides
/// too. Any mapping to sent/delivered/read is therefore a guess, and a wrong "read" is a
/// claim about somebody's behaviour that this server has no business making. The number is
/// reported; naming it needs the owner checking codes against the WhatsApp UI by hand.
public struct DeliveryState: Sendable, Equatable {
    public let rawCode: Int
    /// `ZMESSAGEERRORSTATUS` when it is not zero — 331 rows of the measured library, spread
    /// across many distinct large values that look like error identifiers. Zero is the
    /// healthy case and is reported as nil.
    public let errorCode: Int?

    public init(rawCode: Int, errorCode: Int?) {
        self.rawCode = rawCode
        self.errorCode = (errorCode == 0) ? nil : errorCode
    }
}

/// Somebody named with `@` inside a message.
///
/// WhatsApp writes a mention as `@<digits>` in `ZTEXT`, where the digits are a LID's
/// numeric part and the display name is nowhere in the row. `name` is nil when this
/// database has never learned one, and an unresolved mention is still a mention.
public struct Mention: Sendable, Equatable {
    /// The digits exactly as WhatsApp wrote them.
    public let digits: String
    /// `<digits>@lid`, the address those digits stand for.
    public let jid: String
    public let name: String?

    public init(digits: String, name: String?) {
        self.digits = digits
        self.jid = "\(digits)@lid"
        self.name = name
    }
}

/// One message, whole.
public struct Message: Sendable, Equatable {
    /// `ZWAMESSAGE.Z_PK`.
    public let id: Int64
    public let chatID: Int64
    public let chatName: String
    public let date: Date
    /// `ZSENTDATE`, populated on 6656 of 27137 rows — mostly outgoing ones. Nil is ordinary
    /// and means WhatsApp recorded no separate send time, not that the message was never
    /// sent.
    public let sentDate: Date?
    public let isFromMe: Bool
    /// Who wrote it. Nil on a one-to-one chat, where the sender is either the owner or the
    /// chat itself, and on a group event, whose actor lives in the body.
    public let sender: Identity?
    public let isStarred: Bool
    public let delivery: DeliveryState
    public let body: MessageBody
    /// The words that came with it — the message text, or an attachment's caption. Mentions
    /// are already resolved in place: `@99020605243425` reads as `@Ane (99020605243425)`.
    /// Nil for a message that carries none, which is most photos and every group event.
    public let text: String?
    /// Everyone named with `@` in `text`, resolved where this database can. Listed as well
    /// as inlined, so "was I mentioned" is answerable without parsing the line back apart.
    public let mentions: [Mention]

    public init(
        id: Int64, chatID: Int64, chatName: String, date: Date, sentDate: Date? = nil,
        isFromMe: Bool, sender: Identity?, isStarred: Bool = false,
        delivery: DeliveryState = DeliveryState(rawCode: 0, errorCode: nil),
        body: MessageBody, text: String? = nil, mentions: [Mention] = []
    ) {
        self.id = id
        self.chatID = chatID
        self.chatName = chatName
        self.date = date
        self.sentDate = sentDate
        self.isFromMe = isFromMe
        self.sender = sender
        self.isStarred = isStarred
        self.delivery = delivery
        self.body = body
        self.text = text
        self.mentions = mentions
    }
}

/// One page of messages plus the total the filter matched, so a caller can tell "that is
/// everything" from "there is more behind this page".
public struct MessagePage: Sendable, Equatable {
    public let rows: [Message]
    public let total: Int

    public init(rows: [Message], total: Int) {
        self.rows = rows
        self.total = total
    }
}

// MARK: - Groups

/// One row of `ZWAGROUPMEMBER`.
///
/// `ZFIRSTNAME` is deliberately not read. It is **not a first name**: 72 of the 80
/// populated rows in the measured library are exactly 5 characters, the rest 13, 37 and 53,
/// and not one contains a space. It is a key of some sort, and surfacing it would put a
/// string like `CNXy9` where a reader expects a person.
public struct GroupMember: Sendable, Equatable {
    public let identity: Identity
    /// Nil when `ZISADMIN` is absent from this WhatsApp version's schema, distinct from
    /// `false`.
    public let isAdmin: Bool?
    /// `ZISACTIVE`. False on 86 of 190 member rows across the measured library's six
    /// groups, which settles one thing: this table is **not** a snapshot of who is in a
    /// group today, since a current-membership table would have no reason to keep a row
    /// flagged inactive. What an inactive row means exactly — left voluntarily, removed, or
    /// something else — the column does not say, so `group_get` reports the flag and
    /// attaches no verb to it. Nil when the column is absent.
    public let isActive: Bool?

    public init(identity: Identity, isAdmin: Bool?, isActive: Bool?) {
        self.identity = identity
        self.isAdmin = isAdmin
        self.isActive = isActive
    }
}

/// `ZWAGROUPINFO` for one group chat, plus its member rows.
public struct Group: Sendable, Equatable {
    public let creationDate: Date?
    public let creator: Identity?
    /// `ZSUBJECTTIMESTAMP`: when the group's name was last changed.
    public let subjectChangedDate: Date?
    /// `ZSUBJECTOWNERJID`: who last changed it.
    public let subjectChangedBy: Identity?
    /// `ZPICTUREID`. Not a path — WhatsApp's own opaque id for the current picture.
    public let pictureID: String?
    /// The group's own icon, when a file for it is on this Mac.
    public let picturePath: String?
    public let members: [GroupMember]

    public init(
        creationDate: Date?, creator: Identity?, subjectChangedDate: Date?,
        subjectChangedBy: Identity?, pictureID: String?, picturePath: String? = nil,
        members: [GroupMember]
    ) {
        self.creationDate = creationDate
        self.creator = creator
        self.subjectChangedDate = subjectChangedDate
        self.subjectChangedBy = subjectChangedBy
        self.pictureID = pictureID
        self.picturePath = picturePath
        self.members = members
    }
}

// MARK: - Health

/// What `whatsapp_status` reports about the read path.
public struct DatabaseInfo: Sendable, Equatable {
    public let path: String
    public let exists: Bool
    /// Bytes, or nil when the file is not there.
    public let size: Int64?
    public let modified: Date?
    /// True when a `-wal` sidecar sits next to the database with bytes in it. The store
    /// is opened `immutable=1`, which means the WAL is never read, so anything WhatsApp
    /// has not yet checkpointed is invisible here. Worth reporting rather than hiding.
    public let hasPendingWAL: Bool
    /// Tables the queries need that the file does not have. Empty is the healthy case.
    public let missingTables: [String]
    /// Tables this server reads when they are there and does without when they are not —
    /// link previews and profile pictures. Named in the status output so a missing one
    /// reads as a feature that is off rather than as data that does not exist.
    public let absentOptionalTables: [String]
    public let chatCount: Int?
    public let messageCount: Int?

    public init(
        path: String, exists: Bool, size: Int64?, modified: Date?, hasPendingWAL: Bool,
        missingTables: [String], absentOptionalTables: [String] = [], chatCount: Int?,
        messageCount: Int?
    ) {
        self.path = path
        self.exists = exists
        self.size = size
        self.modified = modified
        self.hasPendingWAL = hasPendingWAL
        self.missingTables = missingTables
        self.absentOptionalTables = absentOptionalTables
        self.chatCount = chatCount
        self.messageCount = messageCount
    }
}
