import Foundation

/// Everything a read tool can ask for, in one value.
///
/// One struct rather than nine parameters repeated across four methods: the filters are
/// the same set every time, and the tools differ only in which of them they populate.
/// Every field mirrors a column the store actually has — there is no filter here that
/// this code would have to compute, which is the line between a filter and a judgment.
public struct MessageQuery: Sendable, Equatable {
    /// `ZWACHATSESSION.Z_PK`. Nil searches every chat.
    public var chatID: Int64?
    /// Case-insensitive substring of the message text.
    public var text: String?
    /// Inclusive lower bound.
    public var after: Date?
    /// Exclusive upper bound, so two adjacent ranges neither overlap nor drop a message.
    public var before: Date?
    public var fromMe: Bool?
    /// Which media kinds to keep. Empty means no kind filter at all, which is right for
    /// `chat_get` and wrong for `media_list` — see `WhatsAppTools.media` for why that tool
    /// substitutes every kind instead.
    public var kinds: [MediaKind]
    public var starredOnly: Bool
    public var limit: Int
    public var offset: Int
    /// Newest first is the default because a conversation is read from its end.
    public var newestFirst: Bool

    public init(
        chatID: Int64? = nil, text: String? = nil, after: Date? = nil, before: Date? = nil,
        fromMe: Bool? = nil, kinds: [MediaKind] = [], starredOnly: Bool = false,
        limit: Int = 50, offset: Int = 0, newestFirst: Bool = true
    ) {
        self.chatID = chatID
        self.text = text
        self.after = after
        self.before = before
        self.fromMe = fromMe
        self.kinds = kinds
        self.starredOnly = starredOnly
        self.limit = limit
        self.offset = offset
        self.newestFirst = newestFirst
    }
}

public struct ChatQuery: Sendable, Equatable {
    /// Case-insensitive substring of the chat name.
    public var name: String?
    public var kinds: [ChatKind]
    public var includeArchived: Bool
    /// `ZHIDDEN` chats are left out by default for the same reason archived ones are: they
    /// are not what somebody means by "my chats". Unlike archived, WhatsApp's own name for
    /// this state is not established, so the flag is reported and not interpreted.
    public var includeHidden: Bool
    public var limit: Int
    public var offset: Int

    public init(
        name: String? = nil, kinds: [ChatKind] = [], includeArchived: Bool = false,
        includeHidden: Bool = false, limit: Int = 50, offset: Int = 0
    ) {
        self.name = name
        self.kinds = kinds
        self.includeArchived = includeArchived
        self.includeHidden = includeHidden
        self.limit = limit
        self.offset = offset
    }
}

/// Why the chat store cannot be read, when it cannot.
///
/// Unlike the sibling servers there is no authorisation case here, and that is the point:
/// WhatsApp's group container is not TCC-protected, so the only failures are a file that
/// is not there and a file that is not shaped the way the queries expect.
public enum StoreAvailability: Sendable, Equatable {
    case ready
    case databaseMissing(path: String)
    case databaseUnreadable(path: String, detail: String)
    /// The file opened but does not carry the tables the queries need — which is what a
    /// WhatsApp update that reorganises the schema would look like from here.
    case schemaUnexpected(missingTables: [String])

    public var isUsable: Bool { self == .ready }
}

/// The seam between the tool layer and WhatsApp's own SQLite file.
///
/// Everything above this protocol is exercised by the tests against an in-memory double
/// and against a fixture database built in a temporary directory; only
/// `SystemWhatsAppStore` opens the real one. Keeping the boundary this thin is what
/// makes the untested surface small enough to check by hand.
///
/// Every method is a read, and this is the only seam there is. The store is opened
/// read-only and immutable, so there is nothing here that could write even if a method
/// were added by mistake.
public protocol WhatsAppStore: Sendable {
    func availability() -> StoreAvailability
    func databaseInfo() -> DatabaseInfo

    func chats(matching query: ChatQuery) async throws -> [Chat]
    func chat(id: Int64) async throws -> Chat?
    func messages(matching query: MessageQuery) async throws -> MessagePage

    /// One message by its row id, for the detail view. Nil when no such row exists.
    func message(id: Int64) async throws -> Message?

    /// The same rows `messages(matching:)` returns, narrowed to those whose body is an
    /// attachment, a location or a contact card. One classification, one row shape: a
    /// photo cannot be described one way here and another way in `chat_get`.
    func media(matching query: MessageQuery) async throws -> MessagePage

    /// `ZWAGROUPINFO` and `ZWAGROUPMEMBER` for one group chat. Nil when the chat has no
    /// group info row at all — which `Dispatch` treats as a fault for a chat already known
    /// to be a group, since every group this server can see was joined through one.
    func group(chatID: Int64) async throws -> Group?
}
