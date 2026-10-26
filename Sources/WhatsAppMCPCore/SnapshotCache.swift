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
    /// True when the source has changed since the copy was taken.
    public let stale: Bool
}

public enum SnapshotError: Error, Equatable {
    case sourceMissing(AllowedDatabase)
    /// macOS refused to open the source; carries the path for the message.
    case accessDenied(AllowedDatabase, String)
    case copyFailed(AllowedDatabase, String)

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
/// container: the source is opened `mode=ro` exactly like the chat store, through its
/// write-ahead log, so a copy holds everything WhatsApp had committed when the backup ran.
/// What that costs is the same as everywhere else here: a read lock on the source's `-shm`
/// index, which SQLite also records the reader in. When nothing has the source open there
/// are no sidecars and the documented `immutable=1` fallback is used (see
/// `ReadOnlyDatabase`), so copying a database WhatsApp is not running on creates nothing
/// beside it.
///
/// The cache holds real message data in plaintext, so the directory is `0700` and every
/// copy `0600`: it must not be readable by another user of this Mac.
///
/// A copy is refreshed when the modification time or size of the source `.sqlite` or its
/// `-wal` differs from the one recorded when it was taken. A struct with no mutable state:
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
    public func snapshot(of database: AllowedDatabase, forceRefresh: Bool = false) throws -> (
        url: URL, info: SnapshotInfo
    ) {
        let source = containerDirectory.appendingPathComponent(database.relativePath)
        switch FileAccess.probe(source.path) {
        case .missing: throw SnapshotError.sourceMissing(database)
        case .denied: throw SnapshotError.accessDenied(database, source.path)
        case .readable, .other: break
        }
        let copy = cacheDirectory.appendingPathComponent(database.cacheFileName)
        let current = Self.stamp(of: source)

        if !forceRefresh, FileManager.default.fileExists(atPath: copy.path),
            let recorded = readRecord(for: database), recorded.stamp == current,
            recorded.scrubVersion == Self.scrubVersion
        {
            return (copy, info(recorded, database: database, stale: false))
        }

        try copyDatabase(from: source, to: copy, database: database)
        let record = Record(stamp: current, copiedAt: Date(), scrubVersion: Self.scrubVersion)
        try writeRecord(record, for: database)
        return (copy, info(record, database: database, stale: false))
    }

    /// The cached copy, opened and proven readable.
    ///
    /// A copy can be unreadable while its stamp still says it is current: it was replaced by
    /// another instance between this call finding it and opening it, or truncated, or half
    /// written by a process that was killed. Reporting that would be wrong — the source is
    /// fine — and so would trusting the stamp. One cheap read decides; if the copy is damaged
    /// it is made again, once, and only a second failure is an error.
    func openReadable(_ database: AllowedDatabase) throws -> (
        database: ReadOnlyDatabase, info: SnapshotInfo
    ) {
        func attempt(forceRefresh: Bool) throws -> (ReadOnlyDatabase, SnapshotInfo) {
            let (url, info) = try snapshot(of: database, forceRefresh: forceRefresh)
            let connection = try ReadOnlyDatabase(path: url.path)
            _ = try connection.tableNames()
            return (connection, info)
        }
        do {
            return try attempt(forceRefresh: false)
        } catch let failure as ReadOnlyDatabase.OpenFailure where failure.isDamaged {
            return try retry(database, attempt)
        } catch let failure as ReadOnlyDatabase.QueryFailure where failure.isDamaged {
            return try retry(database, attempt)
        } catch let failure as ReadOnlyDatabase.OpenFailure {
            throw SnapshotError.copyFailed(database, "the cached copy could not be opened: \(failure.detail)")
        }
    }

    private func retry(
        _ database: AllowedDatabase,
        _ attempt: (Bool) throws -> (ReadOnlyDatabase, SnapshotInfo)
    ) throws -> (ReadOnlyDatabase, SnapshotInfo) {
        do {
            return try attempt(true)
        } catch let failure as ReadOnlyDatabase.OpenFailure {
            throw SnapshotError.copyFailed(database, "the copy is unreadable even after it was made again: \(failure.detail)")
        } catch let failure as ReadOnlyDatabase.QueryFailure {
            throw SnapshotError.copyFailed(database, "the copy is unreadable even after it was made again: \(failure.detail)")
        }
    }

    /// What is cached right now, without copying anything. Databases never copied are
    /// absent. Used by `whatsapp_status`, which must stay cheap and must not take the
    /// first copy of every database as a side effect of being asked how things are.
    public func existingSnapshots() -> [SnapshotInfo] {
        AllowedDatabase.allCases.compactMap { database in
            guard let record = readRecord(for: database) else { return nil }
            let source = containerDirectory.appendingPathComponent(database.relativePath)
            return info(
                record, database: database,
                stale: Self.stamp(of: source) != record.stamp
                    || record.scrubVersion != Self.scrubVersion)
        }
    }

    // MARK: Staleness record

    /// The `.sqlite` and its `-wal`. The source is read through the log, so a message that
    /// is only in the `-wal` is in the copy and must make it stale: stamping the main file
    /// alone would keep serving a copy that is missing everything since the last checkpoint.
    /// The cost is a new copy — the database's own size, not the log's — after each change.
    /// A record written before the log was stamped has no such fields and so never decodes,
    /// which makes it stale, as intended.
    struct Stamp: Equatable, Codable {
        var sqliteModified: Double
        var sqliteSize: Int64
        var walModified: Double
        var walSize: Int64
    }

    struct Record: Codable {
        var stamp: Stamp
        var copiedAt: Date
        /// Which scrubbing rules produced the copy. A copy made by an older version, or
        /// before there was any scrubbing, is stale however unchanged its source is.
        var scrubVersion: Int
    }

    /// Bump whenever `blockedReads` or the way a copy is cleaned changes.
    static let scrubVersion = 3

    static func stamp(of source: URL) -> Stamp {
        let main = try? FileManager.default.attributesOfItem(atPath: source.path)
        let log = try? FileManager.default.attributesOfItem(atPath: source.path + "-wal")
        return Stamp(
            sqliteModified: (main?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
            sqliteSize: (main?[.size] as? NSNumber)?.int64Value ?? 0,
            walModified: (log?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
            walSize: (log?[.size] as? NSNumber)?.int64Value ?? 0)
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
        try PrivateFile.write(try encoder.encode(record), to: url)
    }

    private func info(_ record: Record, database: AllowedDatabase, stale: Bool) -> SnapshotInfo {
        SnapshotInfo(
            database: database, copiedAt: record.copiedAt,
            sourceModified: Date(timeIntervalSince1970: record.stamp.sqliteModified),
            stale: stale)
    }

    // MARK: Copy

    /// SQLite's online-backup API, reading the source through its log and writing a file this
    /// process created. The backup is one read transaction on the source, so the copy is a
    /// consistent snapshot; the stamp is taken first, so a source that changed meanwhile is
    /// simply copied again on the next call.
    private func copyDatabase(from source: URL, to destination: URL, database: AllowedDatabase)
        throws
    {
        let fileManager = FileManager.default
        try PrivateDirectory.ensure(cacheDirectory)
        Self.sweepStaleTemporaries(in: cacheDirectory)

        let temporary = cacheDirectory.appendingPathComponent(
            "\(database.cacheFileName).tmp-\(UUID().uuidString)")
        // The scrubbed copy is rebuilt into this second file, so the first — which still
        // holds the keys in its free pages — never becomes the cache.
        let rebuilt = URL(fileURLWithPath: temporary.path + ".rebuilt")

        // Owner-only from the first byte. `sqlite3_open_v2` would create these with the
        // umask's 0644, and the first of them is the raw backup — keys and all — for as long
        // as the scrub takes. Created empty here, SQLite opens and keeps the existing mode
        // (and gives its journal the same one).
        // Registered before they exist: a signal that arrives between creating a file and
        // registering it would leave the raw backup behind.
        ProcessCleanup.shared.register(path: temporary.path)
        ProcessCleanup.shared.register(path: rebuilt.path)
        defer {
            ProcessCleanup.shared.unregister(path: temporary.path)
            ProcessCleanup.shared.unregister(path: rebuilt.path)
        }
        guard fileManager.createFile(
            atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw SnapshotError.copyFailed(database, "could not create \(temporary.lastPathComponent)") }
        // `rebuilt` cannot be pre-created: `VACUUM INTO` refuses an output file that exists,
        // even an empty one. It is made owner-only by a restrictive umask around that one
        // statement instead (see `PrivateUmask`).
        // The backup copies WhatsApp's "WAL mode" header into the new file, so SQLite creates
        // `-shm` and `-wal` beside it while it is open. Remove them with the temporary.
        defer {
            for base in [temporary.path, rebuilt.path] {
                for suffix in ["", "-shm", "-wal", "-journal"] {
                    try? fileManager.removeItem(atPath: base + suffix)
                }
            }
        }

        func fail(_ detail: String) -> SnapshotError { .copyFailed(database, detail) }

        // Both handles close at the end of this block, before the file is moved.
        do {
            var sourceHandle: OpaquePointer?
            guard
                sqlite3_open_v2(
                    ReadOnlyDatabase.openingURI(for: source.path), &sourceHandle,
                    SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let sourceHandle
            else {
                let detail = sourceHandle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
                let failure = ReadOnlyDatabase.OpenFailure(
                    code: sourceHandle.map { sqlite3_extended_errcode($0) } ?? SQLITE_CANTOPEN,
                    detail: detail, systemErrno: sourceHandle.map { sqlite3_system_errno($0) } ?? 0)
                if let sourceHandle { sqlite3_close_v2(sourceHandle) }
                if failure.isPermissionDenied {
                    throw SnapshotError.accessDenied(database, source.path)
                }
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

            // The page header copied from WhatsApp says "WAL mode". The copy is only ever
            // replaced by a rename, never written in place, so give it a plain rollback
            // journal and no sidecar files.
            sqlite3_exec(destinationHandle, "PRAGMA journal_mode=DELETE", nil, nil, nil)
            do { try Self.scrubKeyMaterial(destinationHandle) } catch let failure as SnapshotError {
                throw failure
            } catch {
                throw fail("key material could not be removed from the copy: \(error)")
            }
            // Scrubbing zeroes what it overwrites, but the backup also copied the free pages
            // and slack where rows WhatsApp deleted long ago still sit — it does not use
            // secure_delete. `VACUUM INTO` writes only live content to a new file, and unlike a
            // plain VACUUM it needs no temporary copy of the database in the system's temp
            // directory.
            var rebuildError: UnsafeMutablePointer<CChar>?
            let escaped = rebuilt.path.replacingOccurrences(of: "'", with: "''")
            let rebuiltCode = PrivateUmask.run {
                sqlite3_exec(destinationHandle, "VACUUM INTO '\(escaped)'", nil, nil, &rebuildError)
            }
            guard rebuiltCode == SQLITE_OK else {
                let detail = rebuildError.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(rebuildError)
                throw fail("the cleaned copy could not be rebuilt: \(detail)")
            }
        }

        try fileManager.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: rebuilt.path)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: rebuilt)
        } else {
            try fileManager.moveItem(at: rebuilt, to: destination)
        }
    }

    // MARK: Scrubbing

    private struct ScrubFailure: Error { let detail: String }

    /// Empties, in the copy, everything `blockedReads` refuses to return, so the cache
    /// does not hold keys that `db_query` was built to withhold. A table is emptied, a
    /// column is set to NULL, and `secure_delete` zeroes the pages the old values sat in
    /// instead of leaving them readable inside the file. If any step fails the whole copy
    /// fails: a half-scrubbed copy is worse than none.
    ///
    /// Only the copy is touched; the source is opened read-only and never written.
    private static func scrubKeyMaterial(_ handle: OpaquePointer) throws {
        func exec(_ sql: String) throws {
            var message: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
                let detail = message.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(message)
                throw ScrubFailure(detail: "\(sql): \(detail)")
            }
        }
        func strings(_ sql: String) throws -> [String] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw ScrubFailure(detail: String(cString: sqlite3_errmsg(handle)))
            }
            defer { sqlite3_finalize(statement) }
            var values: [String] = []
            var code = sqlite3_step(statement)
            while code == SQLITE_ROW {
                if let text = sqlite3_column_text(statement, 1) { values.append(String(cString: text)) }
                code = sqlite3_step(statement)
            }
            // An error part-way is not "no rows": reading it as empty would skip a table that
            // might hold a blocked column, which is failing open.
            guard code == SQLITE_DONE else {
                throw ScrubFailure(detail: String(cString: sqlite3_errmsg(handle)))
            }
            return values
        }
        func quoted(_ name: String) -> String { "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

        try exec("PRAGMA secure_delete = ON")
        // ANALYZE keeps sampled values of indexed columns; a blocked column that is indexed
        // would leave samples of itself in here.
        for statistics in ["sqlite_stat1", "sqlite_stat3", "sqlite_stat4"] {
            if try strings("SELECT 0, name FROM sqlite_master WHERE name = '\(statistics)'").isEmpty == false {
                try exec("DROP TABLE \(statistics)")
            }
        }
        // Virtual tables are left out: WhatsApp's full-text indexes use tokenizers this
        // process does not have, so even asking such a table for its columns fails — and
        // none of the blocked data is in one. Their shadow tables are ordinary tables.
        let tables = try strings(
            "SELECT 0, name FROM sqlite_master WHERE type = 'table' AND sql NOT LIKE 'CREATE VIRTUAL%'")
        for rule in blockedReads {
            let matching = tables.filter {
                rule.table == "*" || $0.caseInsensitiveCompare(rule.table) == .orderedSame
            }
            for table in matching {
                guard let column = rule.column else {
                    try exec("DELETE FROM \(quoted(table))")
                    continue
                }
                let present = try strings("SELECT 0, name FROM pragma_table_info(\(quoted(table).replacingOccurrences(of: "\"", with: "'")))")
                guard let actual = present.first(where: { $0.caseInsensitiveCompare(column) == .orderedSame })
                else { continue }
                try exec("UPDATE \(quoted(table)) SET \(quoted(actual)) = NULL")
            }
        }
    }

    // MARK: Leftovers

    /// How old a temporary must be before it is taken for a dead process's. Another instance
    /// may be mid-copy in the same directory, and a copy touches its file continuously, so
    /// anything modified within the last hour is left alone.
    static let staleAfter: TimeInterval = 3600

    /// Removes what a killed process left in the cache: `<Name>.sqlite.tmp-<uuid>` (the raw,
    /// unscrubbed backup, and its `.rebuilt`) and `tmp/<uuid>` scratch directories. `SIGKILL`
    /// and a power cut run no cleanup, so this is the only thing that ever deletes them.
    static func sweepStaleTemporaries(in directory: URL, now: Date = Date()) {
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
        for name in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        where name.contains(".sqlite.tmp-") {
            let url = directory.appendingPathComponent(name)
            if isStale(url) { try? fileManager.removeItem(at: url) }
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
