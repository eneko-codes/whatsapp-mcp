import Foundation

public enum ToolError: Error, Equatable {
    case storeUnavailable(StoreAvailability)
    case missingArgument(String)
    case badArgument(name: String, reason: String)
    case badDate(argument: String, value: String)
    case rangeInverted
    case chatNotFound(id: Int64)
    case messageNotFound(id: Int64)
    case notAGroup(id: Int64, kind: ChatKind)
    case storeFailure(String)

    public var message: String {
        switch self {
        case .storeUnavailable(let availability):
            return Self.availabilityMessage(availability)

        case .missingArgument(let name):
            return "Missing required argument '\(name)'."

        case .badArgument(let name, let reason):
            return "Argument '\(name)' is not valid: \(reason)"

        case .badDate(let argument, let value):
            return """
                Argument '\(argument)' is not a date this server accepts: '\(value)'

                Use one of:
                \(DateParsing.acceptedForms)
                """

        case .rangeInverted:
            return "'before' is earlier than 'after'. Nothing can match a range that runs backwards."

        case .chatNotFound(let id):
            return """
                No chat exists with id \(id).

                Chat ids are row numbers in WhatsApp's local database, not WhatsApp
                addresses, and they are regenerated if WhatsApp is reinstalled. Call
                chats_list to get a current one rather than reusing an id from an earlier
                conversation.
                """

        case .messageNotFound(let id):
            return """
                No message exists with id \(id).

                Message ids are row numbers in WhatsApp's local database. Take one from
                the first column of chat_get, whatsapp_search or media_list rather than
                reusing an id from an earlier conversation — they are regenerated if
                WhatsApp is reinstalled.
                """

        case .notAGroup(let id, let kind):
            return """
                Chat \(id) is a \(kind.rawValue) chat, not a group.

                group_get only applies to groups. Call chats_list with
                kinds: ["group"] to find one.
                """

        case .storeFailure(let detail):
            return "WhatsApp's database returned an error: \(detail)"
        }
    }

    static func availabilityMessage(_ availability: StoreAvailability) -> String {
        switch availability {
        case .ready:
            return "WhatsApp's chat database is readable."

        case .databaseMissing(let path):
            return """
                WhatsApp's chat database is not at:
                  \(path)

                Nothing is denied — the file simply is not there. That happens when the
                Mac app has never been installed, or has never finished linking to a
                phone, or was removed. Open WhatsApp once and let it sync, then try again.

                This is not a permissions problem: the group container this server reads
                is not protected by macOS privacy controls, so there is no switch to
                enable anywhere.
                """

        case .databaseUnreadable(let path, let detail):
            return """
                WhatsApp's chat database could not be opened: \(detail)

                  \(path)

                The file is opened read-only and immutable, so this is never a lock held
                by WhatsApp — check that the path above still exists and is readable by
                your user.
                """

        case .schemaUnexpected(let missingTables):
            return """
                WhatsApp's database opened, but it does not have the tables this server
                reads: \(missingTables.joined(separator: ", "))

                The layout is WhatsApp's own and undocumented, and it can change in any
                update. This message means it changed. The server refuses to guess rather
                than return plausible-looking nonsense.

                Nothing is wrong with your Mac and nothing needs granting. The fix is a
                new version of this server.
                """
        }
    }
}
