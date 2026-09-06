import Foundation
import MCP
import Testing

@testable import WhatsAppMCPCore

/// Drives the tool layer end to end against the in-memory store. No test here opens a
/// database, and there is nothing here that could send anything: the server has no such
/// path left in it.
@Suite("Tool dispatch")
struct WhatsAppToolsTests {

    private func call(
        _ name: String, _ arguments: [String: Value] = [:],
        store: FakeWhatsAppStore = FakeWhatsAppStore()
    ) async -> (text: String, isError: Bool) {
        let tools = WhatsAppTools(store: store, calendar: Fixtures.calendar)
        let result = await tools.handle(.init(name: name, arguments: arguments))
        guard case .text(let text, _, _) = result.content.first else {
            return ("(no text content)", true)
        }
        return (text, result.isError ?? false)
    }

    private func stocked() -> FakeWhatsAppStore {
        let store = FakeWhatsAppStore()
        store.chatsValue = [
            Fixtures.chat(id: 1, name: "Ane", unread: 2),
            Fixtures.chat(id: 2, name: "Cuadrilla", kind: .group),
            Fixtures.chat(id: 3, name: "Old thread", archived: true),
            Fixtures.chat(id: 4, name: "Quiet one", hidden: true),
        ]
        store.messagesValue = [
            Fixtures.message(id: 10, chatID: 1, chatName: "Ane", text: "bring the bread"),
            Fixtures.message(
                id: 11, chatID: 1, chatName: "Ane", text: "on my way", fromMe: true,
                at: Fixtures.date(2026, 8, 8, 9, 0), starred: true),
            Fixtures.message(
                id: 12, chatID: 2, chatName: "Cuadrilla", text: nil,
                at: Fixtures.date(2026, 8, 7, 20, 0),
                body: Fixtures.attachment(.photo, path: "/tmp/invented/photo.jpg")),
        ]
        return store
    }

    // MARK: Catalogue

    @Test("Every tool has a unique name, title and description")
    func catalogueIsWellFormed() {
        let tools = ToolCatalog.all()
        let names = tools.map(\.name)
        #expect(names.count == Set(names).count)
        for tool in tools {
            #expect(tool.description?.isEmpty == false, "\(tool.name) has no description")
            #expect(tool.title?.isEmpty == false, "\(tool.name) has no title")
        }
    }

    /// The manifest's `tools` array becomes the per-tool permission switches in Claude
    /// Desktop, and is read before the server has ever run — so a tool renamed here and not
    /// there leaves a switch for a tool that no longer exists and none for the one that
    /// replaced it. Nothing at runtime would notice.
    @Test("The extension manifest lists exactly the tools this server has")
    func manifestMatchesTheCatalogue() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // WhatsAppMCPCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
        let data = try Data(
            contentsOf: root.appendingPathComponent("extension/manifest.json"))
        let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let declared = (manifest?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }

        #expect(Set(declared ?? []) == Set(ToolCatalog.all().map(\.name)))
    }

    /// Claude Desktop's schema sanitiser drops a property whose `type` is a union and
    /// hands the model a bare `{}` instead, which stays invisible until a caller happens
    /// to use that field.
    @Test("No property declares a union type")
    func noUnionTypesInSchemas() {
        for tool in ToolCatalog.all() {
            guard case .object(let schema) = tool.inputSchema,
                case .object(let properties)? = schema["properties"]
            else { continue }
            for (property, definition) in properties {
                guard case .object(let fields) = definition else { continue }
                if case .array = fields["type"] {
                    Issue.record("\(tool.name).\(property) declares a union type")
                }
            }
        }
    }

    // MARK: Availability

    @Test("A read is refused when the database is missing")
    func readsRefusedWhenMissing() async {
        let store = stocked()
        store.availabilityValue = .databaseMissing(path: "/invented/ChatStorage.sqlite")
        let (_, isError) = await call(ToolCatalog.chatsName, store: store)
        #expect(isError)
    }

    /// An unexpected shape must not read as "no messages". WhatsApp's storage is private
    /// and undocumented, so a schema change is the likeliest way this server goes wrong.
    @Test("An unexpected schema is reported as a fault, not as an empty result")
    func schemaChangeIsReported() async {
        let store = stocked()
        store.availabilityValue = .schemaUnexpected(missingTables: ["ZWAMESSAGE"])
        let (text, isError) = await call(ToolCatalog.chatsName, store: store)
        #expect(isError)
        #expect(text.contains("ZWAMESSAGE"))
    }

    @Test("whatsapp_status answers even when the database is unreadable")
    func statusWorksWhenUnavailable() async {
        let store = stocked()
        store.availabilityValue = .databaseMissing(path: "/invented/ChatStorage.sqlite")
        let (text, isError) = await call(ToolCatalog.statusName, store: store)
        #expect(!isError)
        #expect(text.contains("read-only"))
    }

    /// A table this server reads when it is there. Absent, its fields come back empty, and
    /// saying so is what keeps "this WhatsApp version has no link previews" from reading as
    /// "nobody has ever sent a link".
    @Test("whatsapp_status names an optional table this WhatsApp version does not have")
    func statusNamesReducedCapability() async {
        let store = stocked()
        store.info = DatabaseInfo(
            path: "/invented/ChatStorage.sqlite", exists: true, size: 1024, modified: nil,
            hasPendingWAL: false, missingTables: [],
            absentOptionalTables: ["ZWAMESSAGEDATAITEM"], chatCount: 4, messageCount: 3)
        let (text, isError) = await call(ToolCatalog.statusName, store: store)
        #expect(!isError)
        #expect(text.contains("ZWAMESSAGEDATAITEM"))
    }

    /// The schema was searched exhaustively for a LID→phone mapping and none exists — see
    /// the comment on `JIDDisplay`. That is a claim about data this server will never be
    /// able to produce, not an implementation gap, so `whatsapp_status` says so up front
    /// rather than leaving a caller to discover it by asking `group_get` or `message_get`
    /// for a phone number a `…@lid` sender simply does not carry.
    @Test("whatsapp_status states plainly that no LID-to-phone mapping exists")
    func statusStatesNoLIDToPhoneMapping() async {
        let (text, isError) = await call(ToolCatalog.statusName, store: stocked())
        #expect(!isError)
        #expect(text.contains("no LID\u{2192}phone mapping"))
    }

    /// Same shape of claim as the LID mapping above: `ZWACHATSESSION` and `ZWAMESSAGE` were
    /// searched for anything resembling "ephemeral", "expir…" or "disappear…" and neither
    /// carries one. Silence on this in `whatsapp_status` would read as "this server just
    /// doesn't surface it yet", which is a different and more hopeful claim than the one
    /// that is actually true.
    @Test("whatsapp_status states plainly that no disappearing-message field exists")
    func statusStatesNoDisappearingMessageField() async {
        let (text, isError) = await call(ToolCatalog.statusName, store: stocked())
        #expect(!isError)
        #expect(text.contains("no disappearing-message setting or TTL"))
    }

    // MARK: Chats

    @Test("chats_list hides archived chats unless asked")
    func archivedChatsAreHiddenByDefault() async {
        let (plain, _) = await call(ToolCatalog.chatsName, store: stocked())
        #expect(!plain.contains("Old thread"))

        let (included, _) = await call(
            ToolCatalog.chatsName, ["include_archived": .bool(true)], store: stocked())
        #expect(included.contains("Old thread"))
    }

    @Test("chats_list hides hidden chats unless asked, and flags them when it shows them")
    func hiddenChatsAreHiddenByDefault() async {
        let (plain, _) = await call(ToolCatalog.chatsName, store: stocked())
        #expect(!plain.contains("Quiet one"))

        let (included, _) = await call(
            ToolCatalog.chatsName, ["include_hidden": .bool(true)], store: stocked())
        #expect(included.contains("Quiet one"))
        #expect(included.contains("(hidden)"))
    }

    // MARK: Messages

    @Test("chat_get returns one conversation")
    func chatGetReturnsConversation() async {
        let (text, isError) = await call(
            ToolCatalog.chatGetName, ["chat_id": .int(1)], store: stocked())
        #expect(!isError)
        #expect(text.contains("bring the bread"))
        #expect(!text.contains("Cuadrilla"))
    }

    @Test("An unknown chat id says so")
    func unknownChatIsNamed() async {
        let (text, isError) = await call(
            ToolCatalog.chatGetName, ["chat_id": .int(999)], store: stocked())
        #expect(isError)
        #expect(text.contains("999"))
    }

    @Test("whatsapp_search passes its filters through unchanged")
    func searchPassesFilters() async {
        let store = stocked()
        let (_, isError) = await call(
            ToolCatalog.searchName,
            [
                "query": .string("bread"), "after": .string("2026-08-01"),
                "before": .string("2026-08-10"), "starred_only": .bool(true),
            ],
            store: store)
        #expect(!isError)
        #expect(store.lastMessageQuery?.text == "bread")
        #expect(store.lastMessageQuery?.starredOnly == true)
        #expect(store.lastMessageQuery?.after != nil)
    }

    @Test("whatsapp_search narrows to a chat when chat_id arrives as a number")
    func searchAppliesNumericChatID() async {
        let store = stocked()
        let (_, isError) = await call(
            ToolCatalog.searchName,
            ["query": .string("bread"), "chat_id": .int(7)],
            store: store)
        #expect(!isError)
        // The catalogue declares chat_id as a number. Decoded as a string it comes back
        // nil, the filter never reaches the store, and the search quietly widens to every
        // chat — a wrong answer wearing the shape of a right one.
        #expect(store.lastMessageQuery?.chatID == 7)
    }

    /// The line a caller sees must not depend on which tool printed it, or two tools
    /// describing the same photo disagree and neither is checkable.
    @Test("chat_get and whatsapp_search print the same line for the same message")
    func chatAndSearchAgreeOnALine() async {
        let store = stocked()
        let (chatText, _) = await call(
            ToolCatalog.chatGetName, ["chat_id": .int(1)], store: store)
        let (searchText, _) = await call(
            ToolCatalog.searchName, ["query": .string("bread"), "chat_id": .int(1)], store: store)

        // Matched on the message id, not on the word: a search header repeats the query
        // back, so "the line containing bread" would find the header instead of the row.
        let chatLine = try? #require(chatText.split(separator: "\n").first { $0.hasPrefix("10  ") })
        let searchLine = try? #require(
            searchText.split(separator: "\n").first { $0.hasPrefix("10  ") })
        // Search names the chat on each line because it spans chats; everything after that
        // is the same rendering.
        #expect(chatLine?.hasSuffix("Ane: bring the bread") == true)
        #expect(searchLine?.hasSuffix("Ane: bring the bread") == true)
    }

    @Test("A range that ends before it starts is refused")
    func invertedRangeIsRefused() async {
        let (_, isError) = await call(
            ToolCatalog.searchName,
            ["after": .string("2026-08-10"), "before": .string("2026-08-01")], store: stocked())
        #expect(isError)
    }

    /// A message with no text is a photo or a sticker, not an empty message. Saying which
    /// is the difference between a record and a gap.
    @Test("A message with no text still says what it was")
    func mediaMessagesSayTheirKind() async {
        let (text, isError) = await call(
            ToolCatalog.chatGetName, ["chat_id": .int(2)], store: stocked())
        #expect(!isError)
        #expect(text.contains("[photo]"))
    }

    @Test("A voice note says it is a voice note, with its length")
    func voiceNoteSaysSoWithLength() async {
        let store = stocked()
        store.messagesValue.append(
            Fixtures.message(
                id: 20, chatID: 1, chatName: "Ane", text: nil,
                at: Fixtures.date(2026, 8, 9, 11, 0),
                body: Fixtures.attachment(.voiceNote, duration: 14)))

        let (text, isError) = await call(
            ToolCatalog.chatGetName, ["chat_id": .int(1)], store: store)
        #expect(!isError)
        #expect(text.contains("[voice note 0:14]"))
    }

    @Test("A deleted message says the text is gone rather than showing an empty line")
    func deletedMessageSaysSo() async {
        let store = stocked()
        store.messagesValue.append(
            Fixtures.message(
                id: 21, chatID: 1, chatName: "Ane", text: nil,
                at: Fixtures.date(2026, 8, 9, 11, 30), body: .deletedForEveryone))

        let (text, isError) = await call(
            ToolCatalog.chatGetName, ["chat_id": .int(1)], store: store)
        #expect(!isError)
        #expect(text.contains("[deleted for everyone]"))
    }

    /// A group event has no sender or body in the ordinary sense, so it must never fall
    /// into the "who: text" layout with the actor's JID standing in for both.
    @Test("A group event renders its actor, subject and code, not a bare JID")
    func groupEventRendersActorAndSubject() async {
        let store = stocked()
        store.messagesValue.append(
            Fixtures.message(
                id: 13, chatID: 2, chatName: "Cuadrilla", text: nil,
                at: Fixtures.date(2026, 8, 8, 10, 0),
                body: .groupEvent(
                    GroupEvent(
                        code: 2,
                        actor: Identity(jid: "1@lid", displayName: "Grace Hopper"),
                        subject: Identity(
                            jid: "34600000002@s.whatsapp.net", displayName: "+34600000002")))))

        let (text, isError) = await call(ToolCatalog.chatGetName, ["chat_id": .int(2)], store: store)

        #expect(!isError)
        #expect(text.contains("[group event 2] Grace Hopper → +34600000002"))
    }

    @Test("A group event with no resolvable subject still names its actor")
    func groupEventWithNoSubjectStillNamesActor() async {
        let store = stocked()
        store.messagesValue.append(
            Fixtures.message(
                id: 14, chatID: 2, chatName: "Cuadrilla", text: nil,
                at: Fixtures.date(2026, 8, 8, 10, 1),
                body: .groupEvent(
                    GroupEvent(
                        code: nil,
                        actor: Identity(
                            jid: "34600000003@s.whatsapp.net", displayName: "+34600000003"),
                        subject: nil))))

        let (text, isError) = await call(ToolCatalog.chatGetName, ["chat_id": .int(2)], store: store)

        #expect(!isError)
        #expect(text.contains("[group event] +34600000003"))
        #expect(!text.contains("→"))
    }

    // MARK: message_get

    @Test("message_get opens one message up, mentions and vCard included")
    func messageGetShowsEverything() async {
        let store = stocked()
        store.messagesValue.append(
            Message(
                id: 30, chatID: 1, chatName: "Ane", date: Fixtures.date(2026, 8, 9, 13, 0),
                sentDate: Fixtures.date(2026, 8, 9, 13, 0), isFromMe: false,
                sender: Identity(jid: "1@lid", displayName: "Ane"),
                delivery: DeliveryState(rawCode: 13, errorCode: nil),
                body: .contactCard(
                    ContactCard(
                        name: "Invented Contact", vcard: "BEGIN:VCARD\nEND:VCARD",
                        typeCode: MessageTypeCode.contact)!),
                text: "here you go @Mikel (99020605243425)",
                mentions: [Mention(digits: "99020605243425", name: "Mikel")]))

        let (text, isError) = await call(
            ToolCatalog.messageGetName, ["message_id": .int(30)], store: store)

        #expect(!isError)
        #expect(text.contains("BEGIN:VCARD"))
        #expect(text.contains("99020605243425@lid"))
        // The delivery code goes up as a number, with the reason it is not given a word.
        #expect(text.contains("delivery code: 13"))
        #expect(text.contains("will not guess"))
    }

    @Test("An unknown message id says so")
    func unknownMessageIsNamed() async {
        let (text, isError) = await call(
            ToolCatalog.messageGetName, ["message_id": .int(999)], store: stocked())
        #expect(isError)
        #expect(text.contains("999"))
    }

    // MARK: media_list

    @Test("media_list narrows to a chat and to the kinds asked for")
    func mediaAppliesChatIDAndKinds() async {
        let store = stocked()
        let (_, isError) = await call(
            ToolCatalog.mediaName,
            ["chat_id": .int(7), "kinds": .array([.string("photo")])],
            store: store)
        #expect(!isError)
        #expect(store.lastMessageQuery?.chatID == 7)
        // Reading an argument name the catalogue does not declare cannot fail loudly; it
        // just yields nothing, so the filter silently never applies.
        #expect(store.lastMessageQuery?.kinds == [.photo])
    }

    /// WhatsApp attaches a `ZWAMEDIAITEM` row to a plain text message for its link-preview
    /// thumbnail, so "has a media row" is not the same question as "is an attachment". An
    /// absent "kinds" argument has to mean every kind this tool covers, not "no filter".
    @Test("media_list defaults to every media kind when none are named")
    func mediaDefaultsToEveryKind() async {
        let store = stocked()
        let (_, isError) = await call(ToolCatalog.mediaName, [:], store: store)
        #expect(!isError)
        #expect(store.lastMessageQuery?.kinds == MediaKind.allCases)
    }

    @Test("An unknown media kind is refused rather than quietly dropped")
    func unknownMediaKindIsRefused() async {
        let (text, isError) = await call(
            ToolCatalog.mediaName, ["kinds": .array([.string("hologram")])], store: stocked())
        #expect(isError)
        #expect(text.contains("hologram"))
    }

    @Test("A downloaded attachment's path reaches the caller")
    func mediaPathIsRendered() async {
        let (text, isError) = await call(ToolCatalog.mediaName, [:], store: stocked())
        #expect(!isError)
        // Without this the tool lists attachments it will not tell you how to open, which
        // is most of the reason to call it at all.
        #expect(text.contains("/tmp/invented/photo.jpg"))
    }

    @Test("An attachment that is not on this Mac is explained rather than left blank")
    func absentMediaPathIsStated() async {
        let store = stocked()
        store.messagesValue = [
            Fixtures.message(
                id: 40, chatID: 1, chatName: "Ane", text: nil,
                body: Fixtures.attachment(.sticker))
        ]
        let (text, isError) = await call(ToolCatalog.mediaName, [:], store: store)

        #expect(!isError)
        #expect(text.contains("not on this Mac"))
    }

    // MARK: group_get

    @Test("group_get lists members and metadata for a group chat")
    func groupGetListsRosterAndMetadata() async {
        let store = stocked()
        store.groupValue[2] = Group(
            creationDate: Fixtures.date(2026, 1, 1),
            creator: Identity(jid: "1@lid", displayName: "Ane"),
            subjectChangedDate: nil, subjectChangedBy: nil, pictureID: nil,
            members: [
                GroupMember(
                    identity: Identity(jid: "1@lid", displayName: "Ane"), isAdmin: true,
                    isActive: true),
                GroupMember(
                    identity: Identity(jid: "2@lid", displayName: "2@lid"), isAdmin: false,
                    isActive: nil),
            ])

        let (text, isError) = await call(
            ToolCatalog.groupGetName, ["chat_id": .int(2)], store: store)
        #expect(!isError)
        #expect(text.contains("Ane"))
        #expect(text.contains("(admin)"))
        #expect(text.contains("2@lid"))
    }

    @Test("group_get refuses a chat that is not a group")
    func groupGetRefusesNonGroupChat() async {
        let (text, isError) = await call(
            ToolCatalog.groupGetName, ["chat_id": .int(1)], store: stocked())
        #expect(isError)
        #expect(text.contains("not a group"))
    }

    @Test("group_get on an unknown chat id says so")
    func groupGetUnknownChatIsNamed() async {
        let (text, isError) = await call(
            ToolCatalog.groupGetName, ["chat_id": .int(999)], store: stocked())
        #expect(isError)
        #expect(text.contains("999"))
    }

    // MARK: Safety

    @Test("An unknown tool name is refused")
    func unknownToolIsRefused() async {
        let (_, isError) = await call("whatsapp_delete_everything", store: stocked())
        #expect(isError)
    }

    /// The whole catalogue, not a hard-coded list: a tool added later that could send,
    /// edit or delete would have to declare itself here, and this fails when it does.
    /// This server reads and nothing else, and that is the property worth pinning.
    @Test("Every tool in the catalogue is read-only")
    func everyToolIsReadOnly() {
        for tool in ToolCatalog.all() {
            #expect(tool.annotations.readOnlyHint == true, "\(tool.name) is not read-only")
            #expect(tool.annotations.destructiveHint != true, "\(tool.name) claims to destroy")
            #expect(tool.annotations.openWorldHint != true, "\(tool.name) claims to leave this Mac")
        }
    }

    @Test("A store failure is reported rather than swallowed")
    func storeFailureIsReported() async {
        let store = stocked()
        store.failure = ToolError.storeFailure("database is locked")
        let (text, isError) = await call(ToolCatalog.chatsName, store: store)
        #expect(isError)
        #expect(text.contains("locked"))
    }
}
