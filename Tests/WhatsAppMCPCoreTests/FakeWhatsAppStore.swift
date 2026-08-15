import Foundation

@testable import WhatsAppMCPCore

/// An in-memory `WhatsAppStore`, and the only double this suite needs now that the
/// server has one seam rather than two.
///
/// Nothing here opens a database. Every fixture below is invented — no chat name, phone
/// number or message body in this file comes from the owner's WhatsApp.
final class FakeWhatsAppStore: WhatsAppStore, @unchecked Sendable {

    var availabilityValue: StoreAvailability = .ready
    var chatsValue: [Chat] = []
    var messagesValue: [Message] = []
    var groupValue: [Int64: Group] = [:]
    var info = DatabaseInfo(
        path: "/invented/ChatStorage.sqlite", exists: true, size: 1024, modified: nil,
        hasPendingWAL: false, missingTables: [], chatCount: 0, messageCount: 0)

    var failure: (any Error)?

    private(set) var lastChatQuery: ChatQuery?
    private(set) var lastMessageQuery: MessageQuery?

    func availability() -> StoreAvailability { availabilityValue }
    func databaseInfo() -> DatabaseInfo { info }

    func chats(matching query: ChatQuery) async throws -> [Chat] {
        if let failure { throw failure }
        lastChatQuery = query

        var matched = chatsValue
        if let name = query.name?.lowercased(), !name.isEmpty {
            matched = matched.filter { $0.name.lowercased().contains(name) }
        }
        if !query.kinds.isEmpty { matched = matched.filter { query.kinds.contains($0.kind) } }
        if !query.includeArchived { matched = matched.filter { !$0.isArchived } }
        if !query.includeHidden { matched = matched.filter { $0.isHidden != true } }
        return Array(matched.dropFirst(query.offset).prefix(query.limit))
    }

    func chat(id: Int64) async throws -> Chat? {
        if let failure { throw failure }
        return chatsValue.first { $0.id == id }
    }

    func messages(matching query: MessageQuery) async throws -> MessagePage {
        if let failure { throw failure }
        lastMessageQuery = query

        var matched = messagesValue
        if let chatID = query.chatID { matched = matched.filter { $0.chatID == chatID } }
        if let text = query.text?.lowercased(), !text.isEmpty {
            matched = matched.filter { ($0.text ?? "").lowercased().contains(text) }
        }
        if let after = query.after { matched = matched.filter { $0.date >= after } }
        if let before = query.before { matched = matched.filter { $0.date < before } }
        if let fromMe = query.fromMe { matched = matched.filter { $0.isFromMe == fromMe } }
        if query.starredOnly { matched = matched.filter(\.isStarred) }
        if !query.kinds.isEmpty {
            matched = matched.filter { message in
                guard let kind = message.mediaKind else { return false }
                return query.kinds.contains(kind)
            }
        }

        matched.sort { query.newestFirst ? $0.date > $1.date : $0.date < $1.date }
        let page = Array(matched.dropFirst(query.offset).prefix(query.limit))
        return MessagePage(rows: page, total: matched.count)
    }

    func message(id: Int64) async throws -> Message? {
        if let failure { throw failure }
        return messagesValue.first { $0.id == id }
    }

    func media(matching query: MessageQuery) async throws -> MessagePage {
        if let failure { throw failure }
        var narrowed = query
        // The real store answers this by requiring a media row; here the body is what says
        // whether there is one, so the two agree on which rows are shared things.
        if narrowed.kinds.isEmpty { narrowed.kinds = MediaKind.allCases }
        let page = try await messages(matching: narrowed)
        lastMessageQuery = query
        return page
    }

    func group(chatID: Int64) async throws -> Group? {
        if let failure { throw failure }
        return groupValue[chatID]
    }
}

extension Message {
    /// Which `media_list` kind this message would be filtered as, or nil when it is not a
    /// shared thing at all.
    var mediaKind: MediaKind? {
        switch body {
        case .attachment(let attachment): return MediaKind(attachment.kind)
        case .location: return .location
        case .contactCard: return .contactCard
        default: return nil
        }
    }
}

// MARK: - Fixtures

enum Fixtures {

    static let now = date(2026, 8, 9, 12, 0)

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return calendar
    }

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0)
        -> Date
    {
        calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    static func chat(
        id: Int64, name: String, kind: ChatKind = .individual, archived: Bool = false,
        hidden: Bool = false, unread: Int = 0
    ) -> Chat {
        Chat(
            id: id, jid: "\(id)@s.whatsapp.net", name: name, kind: kind, isArchived: archived,
            isHidden: hidden, unreadCount: unread, messageCount: 3, lastMessageDate: now,
            lastMessageText: "an invented last line")
    }

    static func message(
        id: Int64, chatID: Int64, chatName: String, text: String?, fromMe: Bool = false,
        at date: Date = now, body: MessageBody = .text, starred: Bool = false,
        mentions: [Mention] = []
    ) -> Message {
        Message(
            id: id, chatID: chatID, chatName: chatName, date: date, isFromMe: fromMe,
            sender: fromMe ? nil : Identity(jid: "\(chatID)@s.whatsapp.net", displayName: chatName),
            isStarred: starred, body: body, text: text, mentions: mentions)
    }

    static func attachment(
        _ kind: AttachmentKind, path: String? = nil, duration: Int? = nil, title: String? = nil
    ) -> MessageBody {
        .attachment(
            Attachment(
                kind: kind, localPath: path, fileSize: 1024, duration: duration, title: title))
    }
}
