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
    /// macOS refused to open a file under WhatsApp's container; carries the path.
    case accessDenied(String)
    case databaseNotAllowed(String)
    case queryRefused(String)
    case explorerUnavailable
    case noAttachment(id: Int64)
    case mediaProblem(String)

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

        case .accessDenied(let path):
            return Self.accessDeniedMessage(path)

        case .databaseNotAllowed(let name):
            return """
                '\(name)' is not a database this server reads.

                Choose one of: \(AllowedDatabase.allCases.map(\.rawValue).joined(separator: ", ")).
                The list is fixed on purpose: WhatsApp's container also holds encryption
                keys and other files that no tool here will open, whatever they are called.
                """

        case .queryRefused(let detail):
            return "db_query refused the statement: \(detail)."

        case .noAttachment(let id):
            return """
                Message \(id) has no attachment file.

                Only photos, videos, GIFs, stickers, voice notes, audio files and documents
                have one. A shared location or contact card is read with message_get, which
                carries its whole content.
                """

        case .mediaProblem(let detail):
            return detail

        case .explorerUnavailable:
            return "The database tools are not configured in this server."
        }
    }

    /// The fix for a refusal, in the order a person does it. The part about updates is not
    /// decoration: macOS ties the grant to the exact program, so every new build of this
    /// server is a program the old grant does not cover.
    static func accessDeniedMessage(_ path: String) -> String {
        """
        macOS refused access to WhatsApp's data folder:
          \(path)

        The file is there. On recent macOS versions another app's data needs Full Disk
        Access for the program that runs this server.

        To fix it:
          1. Open System Settings → Privacy & Security → Full Disk Access.
          2. Turn on (or add with +) the program that runs this server. Claude Desktop runs
             it through its own helper, so look for "whatsapp-mcp"; the exact path is on
             the `binary:` line of whatsapp_status. If you run it by hand, it is the
             terminal or app you started it from.
          3. Quit that app completely and open it again.

        Each rebuilt or updated copy of this server is a new program to macOS: the grant
        given to the old one does not carry over, so repeat this after every update.
        """
    }

    static func availabilityMessage(_ availability: StoreAvailability) -> String {
        switch availability {
        case .ready:
            return "WhatsApp's chat database is readable."

        case .databaseMissing(let path):
            return """
                WhatsApp's chat database is not at:
                  \(path)

                macOS reports that nothing exists at that path — this is not a refusal. That
                happens when the Mac app has never been installed, or has never finished
                linking to a phone, or was removed. Open WhatsApp once and let it sync,
                then try again.
                """

        case .accessDenied(let path):
            return Self.accessDeniedMessage(path)

        case .databaseUnreadable(let path, let detail):
            return """
                WhatsApp's chat database could not be opened: \(detail)

                  \(path)

                The file is opened read-only and immutable, so this is never a lock held
                by WhatsApp. macOS did not report a permission refusal, so check that the
                file is intact; if WhatsApp is mid-update, open it once and try again.
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
