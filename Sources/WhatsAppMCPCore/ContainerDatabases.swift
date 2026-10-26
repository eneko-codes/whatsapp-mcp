import Foundation
import SQLite3

/// The databases `db_*` may read, by exact name.
///
/// An allow-list and not a deny-list, because the container also holds the Signal key
/// material (`enc-key.dat`, `Axolotl*.sqlite`), a certificate revocation list
/// (`BotPKICRL*`), lock files and logs, and a deny-list is one forgotten pattern away from
/// reading them. The caller never supplies a path: it supplies one of these names, and a
/// name that is not a case here has no way to become a file.
///
/// Relative paths are the ones observed on a real container; each is the main `.sqlite` file
/// of its database.
public enum AllowedDatabase: String, CaseIterable, Sendable {
    case chatStorage = "ChatStorage"
    case contacts = "ContactsV2"
    case callHistory = "CallHistory"
    case labels = "Labels"
    case location = "Location"
    case sticker = "Sticker"
    case lid = "LID"
    case emoji = "emoji"
    case localKeyValue = "LocalKeyValue"
    case backedUpKeyValue = "BackedUpKeyValue"
    case extendedChat = "ExtChatDB"
    case status = "statusDB"
    case messagingInfrastructure = "MessagingInfraDB_v2"
    case chatSearch = "fts"
    case channelSearch = "channels-fts"

    public var relativePath: String {
        switch self {
        case .chatStorage: "ChatStorage.sqlite"
        case .contacts: "ContactsV2.sqlite"
        case .callHistory: "CallHistory.sqlite"
        case .labels: "Labels.sqlite"
        case .location: "Location.sqlite"
        case .sticker: "Sticker.sqlite"
        case .lid: "LID.sqlite"
        case .emoji: "emoji.sqlite"
        case .localKeyValue: "LocalKeyValue.sqlite"
        case .backedUpKeyValue: "BackedUpKeyValue.sqlite"
        case .extendedChat: "ExtChatDB/ExtChatDatabase.sqlite"
        case .status: "statusDB/Status.sqlite"
        case .messagingInfrastructure: "MessagingInfraDB_v2/MessagingInfraDatabase.sqlite"
        case .chatSearch: "fts/ChatSearchV5f.sqlite"
        case .channelSearch: "channels-fts/NewsletterChatSearchV1f.sqlite"
        }
    }

    /// Names in the container that must never be copied or read, whatever else changes.
    /// Not consulted to decide what is allowed — the enum does that — but asserted against
    /// every case by a test, so adding a database to the list cannot reintroduce one.
    public static func isForbidden(_ name: String) -> Bool {
        let lowered = name.lowercased()
        let components = lowered.split(separator: "/").map(String.init)
        return components.contains { component in
            component == "enc-key.dat" || component.hasPrefix("axolotl")
                || component.hasPrefix("botpkicrl") || component.hasSuffix(".lock")
                || component == "logs" || component == ".."
                || component.contains("signal")
        }
    }
}

/// What a read of one database knew about its source.
public struct SourceInfo: Sendable, Equatable {
    public let database: AllowedDatabase
    /// When the read began.
    public let readAt: Date
    /// Size of the source's `-wal`, nil when there is none. The read goes through it.
    public let walBytes: Int64?
}

public enum SourceError: Error, Equatable {
    case sourceMissing(AllowedDatabase)
    /// macOS refused to open the source; carries the path for the message.
    case accessDenied(AllowedDatabase, String)
    case readFailed(AllowedDatabase, String)

    /// A refusal by macOS gets its own error, with the steps, rather than the generic
    /// "database returned an error" wrapper.
    var toolError: ToolError {
        if case .accessDenied(_, let path) = self { return .accessDenied(path) }
        return .storeFailure(message)
    }

    public var message: String {
        switch self {
        case .sourceMissing(let database):
            "\(database.rawValue) is not in WhatsApp's container on this Mac — this WhatsApp "
                + "version may not have that database."
        case .accessDenied(_, let path):
            ToolError.accessDeniedMessage(path)
        case .readFailed(let database, let detail):
            "Could not read \(database.rawValue): \(detail)"
        }
    }
}

/// Opens the allow-listed databases in WhatsApp's container, live, read-only.
///
/// There is no copy and nothing is kept: each call opens the source itself, through its
/// write-ahead log, inside one read transaction (see `ReadOnlyDatabase`), and closes it
/// again. Nothing this type does writes a byte of message data anywhere. What reading
/// does change is the source's `-shm` index, which SQLite uses to coordinate readers with
/// WhatsApp's writer.
///
/// The caller never supplies a path: it supplies an `AllowedDatabase`, and a name that is
/// not a case of it has no way to become a file.
public struct ContainerDatabases: Sendable {
    public let containerDirectory: URL

    public init(containerDirectory: URL) {
        self.containerDirectory = containerDirectory
    }

    /// Where this server makes its scratch directories. Nothing stays there between calls.
    public static var defaultScratchDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/whatsapp-mcp")
    }

    func open(_ database: AllowedDatabase) throws -> (database: ReadOnlyDatabase, info: SourceInfo) {
        let source = containerDirectory.appendingPathComponent(database.relativePath)
        switch FileAccess.probe(source.path) {
        case .missing: throw SourceError.sourceMissing(database)
        case .denied: throw SourceError.accessDenied(database, source.path)
        case .readable, .other: break
        }
        let readAt = Date()
        let connection: ReadOnlyDatabase
        do {
            connection = try ReadOnlyDatabase(path: source.path, readTransaction: true)
            // One cheap read decides that the file really is a database before any tool
            // builds a query on it.
            _ = try connection.tableNames()
        } catch let failure as ReadOnlyDatabase.OpenFailure {
            if failure.isPermissionDenied { throw SourceError.accessDenied(database, source.path) }
            throw SourceError.readFailed(database, failure.detail)
        } catch let failure as ReadOnlyDatabase.QueryFailure {
            throw SourceError.readFailed(database, failure.detail)
        }
        let log = try? FileManager.default.attributesOfItem(atPath: source.path + "-wal")
        return (
            connection,
            SourceInfo(
                database: database, readAt: readAt,
                walBytes: (log?[.size] as? NSNumber)?.int64Value)
        )
    }
}

/// Leftovers a killed process can leave in the scratch directory.
enum ScratchSweep {

    /// How old a scratch directory must be before it is taken for a dead process's. Another
    /// instance may be converting audio in the same directory.
    static let staleAfter: TimeInterval = 3600

    /// Removes `tmp/<uuid>` scratch directories a killed process left behind. `SIGKILL` and a
    /// power cut run no cleanup, so this is the only thing that ever deletes them.
    static func sweepStaleDirectories(in directory: URL, now: Date = Date()) {
        let fileManager = FileManager.default
        func modified(_ url: URL) -> Date? {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        // A scratch directory is touched when files appear in it, not while ffmpeg writes one,
        // so a long conversion looks old unless what is inside is looked at too.
        func isStale(_ url: URL) -> Bool {
            var newest = modified(url)
            for name in (try? fileManager.contentsOfDirectory(atPath: url.path)) ?? [] {
                if let inner = modified(url.appendingPathComponent(name)), inner > (newest ?? .distantPast) {
                    newest = inner
                }
            }
            guard let newest else { return false }
            return now.timeIntervalSince(newest) > staleAfter
        }
        let scratch = directory.appendingPathComponent("tmp")
        // Only a real directory: a symlink here would send the sweep into somewhere else.
        guard (try? fileManager.attributesOfItem(atPath: scratch.path))?[.type] as? FileAttributeType
            == .typeDirectory
        else { return }
        for name in (try? fileManager.contentsOfDirectory(atPath: scratch.path)) ?? [] {
            let url = scratch.appendingPathComponent(name)
            if isStale(url) { try? fileManager.removeItem(at: url) }
        }
    }
}
