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

    /// Where the copy lives, flat inside the cache directory.
    var cacheFileName: String { "\(rawValue).sqlite" }

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

/// What is known about one cached copy.
public struct SnapshotInfo: Sendable, Equatable {
    public let database: AllowedDatabase
    /// When the copy was taken.
    public let copiedAt: Date
    /// Modification time of WhatsApp's `.sqlite` when the copy was taken.
    public let sourceModified: Date
    /// True when a non-empty `-wal` sat beside the source at that moment. The source is
    /// read `immutable=1`, so its write-ahead log is never applied and rows WhatsApp has
    /// not yet checkpointed are not in the copy.
    public let walPending: Bool
    /// True when the source has changed since the copy was taken.
    public let stale: Bool
}

public enum SnapshotError: Error, Equatable {
    case sourceMissing(AllowedDatabase)
    case copyFailed(AllowedDatabase, String)

    public var message: String {
        switch self {
        case .sourceMissing(let database):
            "\(database.rawValue) is not in WhatsApp's container on this Mac — this WhatsApp "
                + "version may not have that database."
        case .copyFailed(let database, let detail):
            "Could not copy \(database.rawValue) into the cache: \(detail)"
        }
    }
}

/// A private copy of each allowed database, so `db_*` reads never touch WhatsApp's files
/// more than once per change.
///
/// This is the only place this server writes, and it writes only under `cacheDirectory`
/// (`~/Library/Caches/whatsapp-mcp` by default). Nothing is ever written into WhatsApp's
/// container: the source is opened `mode=ro&immutable=1` exactly like the chat store, so
/// copying takes no lock and creates no `-shm` beside WhatsApp's own files. Rows still in
/// the source's write-ahead log are not in a copy; that is reported, not hidden. The cost is the
/// same as everywhere else here and is reported in `SnapshotInfo.walPending`.
///
/// The cache holds real message data in plaintext, so the directory is `0700` and every
/// copy `0600`: it must not be readable by another user of this Mac.
///
/// A copy is refreshed when the modification time or size of the source `.sqlite` differs
/// from the one recorded when it was taken. A struct with no mutable state:
/// concurrent refreshes write to a uniquely named temporary file and rename it into place,
/// so the worst case is two identical copies, never a half-written one.
public struct SnapshotCache: Sendable {
    public let containerDirectory: URL
    public let cacheDirectory: URL

    public init(containerDirectory: URL, cacheDirectory: URL) {
        self.containerDirectory = containerDirectory
        self.cacheDirectory = cacheDirectory
    }

    public static var defaultCacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/whatsapp-mcp")
    }

    /// The copy of `database`, taken now if there is none or the source has changed.
    public func snapshot(of database: AllowedDatabase) throws -> (url: URL, info: SnapshotInfo) {
        let source = containerDirectory.appendingPathComponent(database.relativePath)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw SnapshotError.sourceMissing(database)
        }
        let copy = cacheDirectory.appendingPathComponent(database.cacheFileName)
        let current = Self.stamp(of: source)

        if FileManager.default.fileExists(atPath: copy.path),
            let recorded = readRecord(for: database), recorded.stamp == current
        {
            return (copy, info(recorded, database: database, stale: false))
        }

        try copyDatabase(from: source, to: copy, database: database)
        let record = Record(
            stamp: current, copiedAt: Date(), walPending: Self.hasWAL(beside: source))
        try writeRecord(record, for: database)
        return (copy, info(record, database: database, stale: false))
    }

    /// What is cached right now, without copying anything. Databases never copied are
    /// absent. Used by `whatsapp_status`, which must stay cheap and must not take the
    /// first copy of every database as a side effect of being asked how things are.
    public func existingSnapshots() -> [SnapshotInfo] {
        AllowedDatabase.allCases.compactMap { database in
            guard let record = readRecord(for: database) else { return nil }
            let source = containerDirectory.appendingPathComponent(database.relativePath)
            return info(
                record, database: database, stale: Self.stamp(of: source) != record.stamp)
        }
    }

    // MARK: Staleness record

    /// Deliberately the `.sqlite` alone. The source is read `immutable`, so what sits in
    /// its `-wal` can never reach a copy: stamping the WAL would recopy a multi-gigabyte
    /// file on every incoming message and produce a copy identical to the last one.
    struct Stamp: Equatable, Codable {
        var sqliteModified: Double
        var sqliteSize: Int64
    }

    struct Record: Codable {
        var stamp: Stamp
        var copiedAt: Date
        var walPending: Bool
    }

    static func stamp(of source: URL) -> Stamp {
        let attributes = try? FileManager.default.attributesOfItem(atPath: source.path)
        return Stamp(
            sqliteModified: (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
            sqliteSize: (attributes?[.size] as? NSNumber)?.int64Value ?? 0)
    }

    /// True when a `-wal` with bytes in it sits beside the source. A WAL WhatsApp has fully
    /// checkpointed but not truncated also counts, so this can over-report.
    static func hasWAL(beside source: URL) -> Bool {
        let wal = URL(fileURLWithPath: source.path + "-wal")
        let size = (try? FileManager.default.attributesOfItem(atPath: wal.path))?[.size]
        return ((size as? NSNumber)?.int64Value ?? 0) > 0
    }

    private func recordURL(for database: AllowedDatabase) -> URL {
        cacheDirectory.appendingPathComponent("\(database.rawValue).stamp.json")
    }

    private func readRecord(for database: AllowedDatabase) -> Record? {
        guard let data = try? Data(contentsOf: recordURL(for: database)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(Record.self, from: data)
    }

    private func writeRecord(_ record: Record, for database: AllowedDatabase) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let url = recordURL(for: database)
        try encoder.encode(record).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func info(_ record: Record, database: AllowedDatabase, stale: Bool) -> SnapshotInfo {
        SnapshotInfo(
            database: database, copiedAt: record.copiedAt,
            sourceModified: Date(timeIntervalSince1970: record.stamp.sqliteModified),
            walPending: record.walPending, stale: stale)
    }

    // MARK: Copy

    /// SQLite's online-backup API, reading the source `immutable` and writing a file this
    /// process created. A plain file copy would race WhatsApp's own writes and could catch
    /// a page mid-update; the backup API reads a consistent set of pages.
    private func copyDatabase(from source: URL, to destination: URL, database: AllowedDatabase)
        throws
    {
        let fileManager = FileManager.default
        try PrivateDirectory.ensure(cacheDirectory)

        let temporary = cacheDirectory.appendingPathComponent(
            "\(database.cacheFileName).tmp-\(UUID().uuidString)")
        // The backup copies WhatsApp's "WAL mode" header into the new file, so SQLite creates
        // `-shm` and `-wal` beside it while it is open. Remove them with the temporary.
        defer {
            for suffix in ["", "-shm", "-wal", "-journal"] {
                try? fileManager.removeItem(atPath: temporary.path + suffix)
            }
        }

        func fail(_ detail: String) -> SnapshotError { .copyFailed(database, detail) }

        // Both handles close at the end of this block, before the file is moved.
        do {
            var sourceHandle: OpaquePointer?
            guard
                sqlite3_open_v2(
                    ReadOnlyDatabase.uri(for: source.path), &sourceHandle,
                    SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let sourceHandle
            else {
                let detail = sourceHandle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
                if let sourceHandle { sqlite3_close_v2(sourceHandle) }
                throw fail(detail)
            }
            defer { sqlite3_close_v2(sourceHandle) }

            var destinationHandle: OpaquePointer?
            guard
                sqlite3_open_v2(
                    temporary.path, &destinationHandle,
                    SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
                let destinationHandle
            else {
                let detail =
                    destinationHandle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
                if let destinationHandle { sqlite3_close_v2(destinationHandle) }
                throw fail(detail)
            }
            defer { sqlite3_close_v2(destinationHandle) }

            guard
                let backup = sqlite3_backup_init(destinationHandle, "main", sourceHandle, "main")
            else { throw fail(String(cString: sqlite3_errmsg(destinationHandle))) }
            let stepCode = sqlite3_backup_step(backup, -1)
            let finishCode = sqlite3_backup_finish(backup)
            guard stepCode == SQLITE_DONE, finishCode == SQLITE_OK else {
                throw fail(String(cString: sqlite3_errstr(stepCode == SQLITE_DONE ? finishCode : stepCode)))
            }

            // The page header copied from WhatsApp says "WAL mode". The copy is read
            // `immutable`, so give it a plain rollback journal and no sidecar files.
            sqlite3_exec(destinationHandle, "PRAGMA journal_mode=DELETE", nil, nil, nil)
        }

        try fileManager.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }
}
