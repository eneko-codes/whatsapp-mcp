import Foundation
import SQLite3

/// A read-only connection to a SQLite file.
///
/// SQLite comes from the system module macOS already ships. There is no package here for
/// the same reason there is no argument parser: a dependency has to earn its place, and
/// `import SQLite3` does this job in one import.
///
/// The connection is opened `mode=ro`, and deliberately not `immutable=1`:
///
/// - `mode=ro` refuses every write at the SQLite level rather than by convention. This
///   server reads someone's live chat history, and "we never call UPDATE" is a promise
///   the code makes to itself; a read-only handle is one the library enforces.
///   `PRAGMA query_only` is set on top of it as a second, independent refusal.
/// - Not `immutable=1`, because WhatsApp keeps its databases in WAL mode and the newest
///   messages can sit only in the `-wal` file, which an immutable reader never looks at.
///   `immutable=1` is also a promise to SQLite that nothing changes the file, which is
///   false while WhatsApp runs; SQLite documents that it may then return incorrect
///   results or `SQLITE_CORRUPT` (https://www.sqlite.org/uri.html).
///
/// What reading the log costs is a shared lock on the `-shm` index for the length of one
/// read transaction, and SQLite records the reader in that index — so the `-shm` file's
/// bytes and modification time change when this server reads. It is a coordination file,
/// never message data. In WAL mode a reader never blocks the writer, and a read-only
/// connection cannot checkpoint.
///
/// SQLite documents when a read-only connection can open a WAL database: the `-shm` and
/// `-wal` files exist and are readable, the directory is writable so they can be created,
/// or the file is opened `immutable` (https://www.sqlite.org/wal.html). A `mode=ro`
/// connection to a database whose sidecars are gone failed to open when tried, with
/// `SQLITE_CANTOPEN`. Sidecars are gone only when no connection has the database open,
/// which is the case whenever WhatsApp is not running, and then nothing is changing the
/// file — exactly what `immutable=1` promises. So that, and only that, is when it is used.
final class ReadOnlyDatabase {
    private let handle: OpaquePointer

    /// A failure to open, kept separate from `ToolError` so this file has no opinion
    /// about how the problem should be explained.
    struct OpenFailure: Error {
        let code: Int32
        let detail: String
        /// `errno` from the failed `open(2)`, 0 when SQLite did not get that far.
        var systemErrno: Int32 = 0

        /// macOS refusing the open — a privacy grant that is missing — as opposed to a file
        /// that is absent or damaged. Apple's SQLite reports it as `SQLITE_AUTH` ("authorization
        /// denied") rather than `CANTOPEN`, so the code is checked as well as `errno`.
        var isDamaged: Bool { ReadOnlyDatabase.isDamageCode(code) && !isPermissionDenied }

        var isPermissionDenied: Bool {
            [EPERM, EACCES].contains(systemErrno) || code == SQLITE_AUTH || code == SQLITE_PERM
                || (code & 0xFF) == SQLITE_AUTH || (code & 0xFF) == SQLITE_PERM
        }
    }

    struct QueryFailure: Error {
        let sql: String
        let detail: String
        var code: Int32 = SQLITE_ERROR

        var isDamaged: Bool { ReadOnlyDatabase.isDamageCode(code) }
    }

    /// I/O error, corruption, "not a database", cannot open: what a cached copy that was
    /// replaced under a reader, or truncated, or half-written reports. A file in that state
    /// is made again rather than reported, because the source it came from is fine.
    static func isDamageCode(_ code: Int32) -> Bool {
        [SQLITE_IOERR, SQLITE_CORRUPT, SQLITE_NOTADB, SQLITE_CANTOPEN].contains(code & 0xFF)
    }

    /// `file:` URI with the path percent-encoded, because the query string after `?` is
    /// how the read-only flag is set at all. A raw path would be taken literally and the
    /// flag would silently not apply.
    ///
    /// Everything outside an explicit unreserved set is encoded: `?` would start the query
    /// string, `#` the fragment and `%` an escape, so a path containing one of them could
    /// otherwise open a different file — or a writable one.
    static func uri(for path: String, immutable: Bool = false) -> String {
        let unreserved = CharacterSet(
            charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/:@!$&'()*+,;=")
        let encoded = path.addingPercentEncoding(withAllowedCharacters: unreserved) ?? path
        return "file:\(encoded)?mode=ro" + (immutable ? "&immutable=1" : "")
    }

    /// Whether a connection currently has this database open in WAL mode. The `-shm` file
    /// exists for exactly as long as one does.
    static func hasJournalSidecars(path: String) -> Bool {
        FileManager.default.fileExists(atPath: path + "-wal")
            && FileManager.default.fileExists(atPath: path + "-shm")
    }

    /// `mode=ro`, through the log, whenever another process has the file open; the
    /// documented `immutable=1` fallback only when it demonstrably has not. A private copy
    /// in the cache has no sidecars, so it is opened immutable, which changes nothing: this
    /// server is the only thing that replaces it, and it does so by renaming a new file in.
    static func openingURI(for path: String) -> String {
        uri(for: path, immutable: !hasJournalSidecars(path: path))
    }

    /// `readTransaction` begins a read transaction that lasts until the connection closes,
    /// so every query on it sees one snapshot even while WhatsApp is writing. Connections
    /// are short-lived here, so closing is what ends it.
    init(path: String, readTransaction: Bool = false) throws {
        var connection: OpaquePointer?
        // FULLMUTEX because a connection is short-lived here but the MCP server is
        // asynchronous, and a serialised handle costs nothing measurable on a read.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(Self.openingURI(for: path), &connection, flags, nil)
        guard code == SQLITE_OK, let connection else {
            let detail =
                connection.map { String(cString: sqlite3_errmsg($0)) }
                ?? String(cString: sqlite3_errstr(code))
            let systemErrno = connection.map { sqlite3_system_errno($0) } ?? 0
            let extended = connection.map { sqlite3_extended_errcode($0) } ?? code
            if let connection { sqlite3_close_v2(connection) }
            throw OpenFailure(code: extended, detail: detail, systemErrno: systemErrno)
        }
        handle = connection

        if sqlite3_exec(connection, "PRAGMA query_only = ON", nil, nil, nil) != SQLITE_OK
            || (readTransaction && sqlite3_exec(connection, "BEGIN", nil, nil, nil) != SQLITE_OK)
        {
            let detail = String(cString: sqlite3_errmsg(connection))
            let extended = sqlite3_extended_errcode(connection)
            sqlite3_close_v2(connection)
            throw OpenFailure(code: extended, detail: detail)
        }

        // Case-insensitive containment that also folds accents, which SQLite's own
        // `lower()` and `LIKE` do not: the system library is built without ICU, so both
        // are ASCII-only and a search for "angel" would miss "Ángel". The function is a
        // bare C pointer with no captured state, which is the only kind SQLite can hold.
        sqlite3_create_function_v2(
            handle, "wa_contains", 2, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil,
            containsImplementation, nil, nil, nil)
    }

    deinit { sqlite3_close_v2(handle) }

    /// Names of every table in the file. Used to tell "WhatsApp reorganised its schema"
    /// apart from "the query has a bug", which are otherwise the same error.
    func tableNames() throws -> Set<String> {
        var names: Set<String> = []
        try query("SELECT name FROM sqlite_master WHERE type = 'table'") { row in
            if let name = row.text(0) { names.insert(name) }
        }
        return names
    }

    /// Names of every column on one table, empty when the table does not exist.
    ///
    /// `PRAGMA table_info` cannot be bound as a query parameter — SQLite only accepts a
    /// literal table name there — so the name is interpolated rather than passed as a
    /// binding. That is safe here because every caller passes one of this file's own
    /// `ZWA…` constants, never anything a caller of this server supplies.
    ///
    /// The querying code uses this to build a `SELECT` out of whichever of a table's
    /// expected columns are actually present, rather than assuming a column exists because
    /// it did on the library this server was last measured against — the schema is
    /// WhatsApp's own and undocumented, and a renamed or dropped column should mean "that
    /// one field comes back nil", not a query failure covering every field on the row.
    func columnNames(of table: String) throws -> Set<String> {
        var names: Set<String> = []
        try query("PRAGMA table_info(\(table))") { row in
            if let name = row.text(1) { names.insert(name) }
        }
        return names
    }

    /// Prepares, binds, steps, and hands each row to `consume`.
    ///
    /// Also the only way a write could be attempted, which is deliberate: `WriteRefused`
    /// in the test suite runs an UPDATE through here and expects SQLite itself to refuse
    /// it, proving the read-only handle rather than trusting it.
    func query(_ sql: String, _ bindings: [SQLiteBinding] = [], row consume: (Row) throws -> Void)
        throws
    {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else {
            let detail = String(cString: sqlite3_errmsg(handle))
            sqlite3_finalize(statement)
            throw QueryFailure(sql: sql, detail: detail, code: sqlite3_extended_errcode(handle))
        }
        defer { sqlite3_finalize(statement) }

        for (offset, binding) in bindings.enumerated() {
            binding.bind(to: statement, at: Int32(offset + 1))
        }

        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                try consume(Row(statement: statement))
            case SQLITE_DONE:
                return
            default:
                throw QueryFailure(
                    sql: sql, detail: String(cString: sqlite3_errmsg(handle)),
                    code: sqlite3_extended_errcode(handle))
            }
        }
    }

    /// Why `selectRows` refused to run a statement, or stopped it.
    enum SelectRefusal: Error, Equatable {
        case empty
        case notASingleSelect
        case notReadOnly
        case timedOut
        case blocked
        case failed(String)

        var detail: String {
            switch self {
            case .empty: "the statement is empty"
            case .notASingleSelect:
                "only one SELECT (or WITH … SELECT) statement is accepted, with no leading comment"
            case .notReadOnly: "the statement would change the database"
            case .timedOut: "the statement ran past its time limit and was stopped"
            case .blocked:
                "the statement reads key material or raw protocol queues, which no tool here returns"
            case .failed(let detail): detail
            }
        }
    }

    struct SelectedRows: Equatable {
        var columns: [String]
        var rows: [[String]]
        var truncated: Bool
    }

    /// Runs caller-supplied SQL, which is the one place in this project where a string from
    /// outside reaches `sqlite3_prepare_v2` unbound. Three gates stand in front of it, and
    /// each covers a hole the others leave:
    ///
    /// - the text must be a single statement that begins with `SELECT` or `WITH`, because
    ///   `sqlite3_stmt_readonly` reports `ATTACH` and `DETACH` as read-only (they alter the
    ///   connection, not the file) and would let them through;
    /// - `sqlite3_stmt_readonly` must agree, which catches `WITH … DELETE`;
    /// - the connection itself is `mode=ro` with `query_only` on, so a mistake in the two
    ///   gates above still cannot write.
    ///
    /// A progress handler enforces the time limit: a cross join over WhatsApp's message
    /// table would otherwise hold the process for as long as it liked.
    func selectRows(
        _ sql: String, maxRows: Int, maxCellLength: Int = 2000,
        maxTotalCharacters: Int = 200_000, timeLimit: TimeInterval = 5
    ) throws -> SelectedRows {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SelectRefusal.empty }
        let upper = trimmed.uppercased()
        let startsWithSelect = ["SELECT", "WITH"].contains { keyword in
            guard upper.hasPrefix(keyword) else { return false }
            let next = upper.dropFirst(keyword.count).first
            return next == nil || !(next!.isLetter || next!.isNumber || next! == "_")
        }
        guard startsWithSelect else { throw SelectRefusal.notASingleSelect }

        // `tail` points into the C buffer Swift makes for this call and is dead once the
        // closure returns, so the unparsed remainder is read inside it. Reading it later
        // sees freed memory, which looks like "nothing left" and lets a second statement
        // through.
        // Columns and tables that hold key material or undecrypted protocol payloads are
        // refused at prepare time, whatever the statement does with them — hex(), CAST and
        // a subquery all go through the same read. See `blockedReads`.
        sqlite3_set_authorizer(handle, authorizeRead, nil)
        defer { sqlite3_set_authorizer(handle, nil, nil) }

        var prepared: OpaquePointer?
        var hasSecondStatement = false
        let accepted: Bool = trimmed.withCString { text in
            var tail: UnsafePointer<CChar>?
            guard sqlite3_prepare_v2(handle, text, -1, &prepared, &tail) == SQLITE_OK else {
                return false
            }
            // What follows is either nothing, a semicolon, a comment, or a second
            // statement. Asking SQLite settles it: preparing the remainder gives no
            // statement for the first three and a statement for the last.
            guard let tail else { return true }
            var second: OpaquePointer?
            let code = sqlite3_prepare_v2(handle, tail, -1, &second, nil)
            if code != SQLITE_OK || second != nil { hasSecondStatement = true }
            sqlite3_finalize(second)
            return true
        }
        guard accepted, let statement = prepared else {
            let detail = String(cString: sqlite3_errmsg(handle))
            sqlite3_finalize(prepared)
            throw (detail.contains("not authorized") || detail.contains("is prohibited"))
                ? SelectRefusal.blocked : SelectRefusal.failed(detail)
        }
        defer { sqlite3_finalize(statement) }

        guard !hasSecondStatement else { throw SelectRefusal.notASingleSelect }
        guard sqlite3_stmt_readonly(statement) != 0 else { throw SelectRefusal.notReadOnly }

        // The progress handler only runs between VM steps, so one function call such as
        // zeroblob(400000000) is never interrupted. Capping the size of any value the
        // statement can build bounds that. Restored afterwards because the same
        // connection type reads WhatsApp's own large blobs elsewhere.
        let previousLengthLimit = sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, 10_000_000)
        defer { sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, previousLengthLimit) }

        let deadline = Deadline(limit: timeLimit)
        let result: SelectedRows = try withExtendedLifetime(deadline) {
            sqlite3_progress_handler(
                handle, 1000,
                { context in
                    guard let context else { return 0 }
                    return Unmanaged<Deadline>.fromOpaque(context).takeUnretainedValue().expired
                        ? 1 : 0
                }, Unmanaged.passUnretained(deadline).toOpaque())
            defer { sqlite3_progress_handler(handle, 0, nil, nil) }

            let columnCount = sqlite3_column_count(statement)
            var result = SelectedRows(
                columns: (0..<columnCount).map { String(cString: sqlite3_column_name(statement, $0)) },
                rows: [], truncated: false)

            var totalCharacters = 0
            // Even one row of very wide cells must fit the cap, so shrink the cells.
            let cellLength = max(20, min(maxCellLength, maxTotalCharacters / max(1, Int(columnCount))))
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    if result.rows.count == maxRows {
                        result.truncated = true
                        return result
                    }
                    let row = (0..<columnCount).map {
                        Self.render(statement, $0, maxLength: cellLength)
                    }
                    // Rows and cells are capped, but a statement can still name thousands
                    // of columns; this bounds the answer as a whole.
                    totalCharacters += row.reduce(0) { $0 + $1.count }
                    if totalCharacters > maxTotalCharacters, !result.rows.isEmpty {
                        result.truncated = true
                        return result
                    }
                    result.rows.append(row)
                case SQLITE_DONE:
                    return result
                case SQLITE_INTERRUPT:
                    throw SelectRefusal.timedOut
                default:
                    throw SelectRefusal.failed(String(cString: sqlite3_errmsg(handle)))
                }
            }
        }
        return result
    }

    /// Text as text, numbers as numbers, and a blob as its size: bytes of a WhatsApp
    /// protobuf are never going to be useful pasted into a chat window.
    private static func render(_ statement: OpaquePointer, _ index: Int32, maxLength: Int) -> String {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL:
            return "NULL"
        case SQLITE_INTEGER:
            return String(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return String(sqlite3_column_double(statement, index))
        case SQLITE_BLOB:
            return "<blob \(sqlite3_column_bytes(statement, index)) bytes>"
        default:
            guard let pointer = sqlite3_column_text(statement, index) else { return "NULL" }
            let text = String(cString: pointer)
            return text.count > maxLength ? String(text.prefix(maxLength)) + "…" : text
        }
    }

    private final class Deadline {
        private let end: Date
        init(limit: TimeInterval) { end = Date(timeIntervalSinceNow: limit) }
        var expired: Bool { Date() > end }
    }

    /// One row, valid only for the duration of the callback that receives it.
    struct Row {
        let statement: OpaquePointer

        func text(_ index: Int32) -> String? {
            guard let pointer = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: pointer)
        }

        func int(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }

        /// A blob column's bytes, copied. Nil for NULL; an empty blob is empty data.
        func data(_ index: Int32) -> Data? {
            guard !isNull(index) else { return nil }
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let pointer = sqlite3_column_blob(statement, index) else {
                return Data()
            }
            return Data(bytes: pointer, count: count)
        }

        func bool(_ index: Int32) -> Bool { sqlite3_column_int64(statement, index) != 0 }

        func isNull(_ index: Int32) -> Bool {
            sqlite3_column_type(statement, index) == SQLITE_NULL
        }

        func optionalInt(_ index: Int32) -> Int64? {
            isNull(index) ? nil : sqlite3_column_int64(statement, index)
        }

        func optionalDouble(_ index: Int32) -> Double? {
            isNull(index) ? nil : sqlite3_column_double(statement, index)
        }

        /// Core Data stores a `TIMESTAMP` as seconds since 2001-01-01 UTC, which is
        /// exactly `Date`'s own reference date — so this is a cast, not a conversion.
        func date(_ index: Int32) -> Date? {
            guard !isNull(index) else { return nil }
            return Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, index))
        }
    }
}

/// A value bound to a `?` placeholder.
///
/// Every caller-supplied string reaches SQLite through one of these. There is no string
/// interpolation into SQL anywhere in this project except for lists of integers the code
/// itself produced, which is the injection guarantee.
enum SQLiteBinding {
    case text(String)
    case int(Int64)
    case double(Double)
    case null

    /// SQLITE_TRANSIENT: SQLite must copy the bytes, because the Swift string backing
    /// them is free to be deallocated the moment this function returns.
    private static let transient = unsafeBitCast(
        -1, to: sqlite3_destructor_type.self)

    func bind(to statement: OpaquePointer, at index: Int32) {
        switch self {
        case .text(let value):
            sqlite3_bind_text(statement, index, value, -1, Self.transient)
        case .int(let value):
            sqlite3_bind_int64(statement, index, value)
        case .double(let value):
            sqlite3_bind_double(statement, index, value)
        case .null:
            sqlite3_bind_null(statement, index)
        }
    }
}

/// `wa_contains(haystack, needle)` → 1 when `needle` appears in `haystack`, ignoring case
/// and diacritics. A NULL haystack is not a match rather than an error, because a message
/// with no text is an ordinary row here, not a fault.
private let containsImplementation:
    @convention(c) (OpaquePointer?, Int32, UnsafeMutablePointer<OpaquePointer?>?) -> Void = {
        context, count, arguments in
        guard count == 2, let arguments,
            let haystackBytes = sqlite3_value_text(arguments[0]),
            let needleBytes = sqlite3_value_text(arguments[1])
        else {
            sqlite3_result_int(context, 0)
            return
        }
        let haystack = String(cString: haystackBytes)
        let needle = String(cString: needleBytes)
        guard !needle.isEmpty else {
            sqlite3_result_int(context, 1)
            return
        }
        let found =
            haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        sqlite3_result_int(context, found ? 1 : 0)
    }

/// What `db_query` may never read, by `(table, column)`; a nil column blocks the table.
///
/// Chosen from the structure of the databases (never from their rows): the extended-chat
/// store keeps feature keys in `feature_key_store.key`; the messaging-infrastructure
/// queues hold undecrypted protocol stanzas and their decryption metadata; and the two
/// key-value stores keep opaque blobs in `ZVALUE` that are not known to be free of
/// secrets. A block list is the wrong tool for deciding which *files* are readable —
/// `AllowedDatabase` does that — but it is the right one for columns inside a file that
/// is otherwise wanted.
let blockedReads: [(table: String, column: String?)] = [
    ("feature_key_store", nil),
    ("group_enc_key_mapping", nil),
    ("unordered_queue", nil),
    ("e2ee_queue", nil),
    ("chat_queue", nil),
    ("ZWAKEYVALUEELEMENT", "ZVALUE"),
    ("message_conditional_reveal", nil),
    // Media decryption keys, wherever they sit ("*" is any table).
    ("*", "ZMEDIAKEY"),
    ("extended_media_item", "media_key"),
    // Undecrypted payloads and opaque account blobs.
    ("pending_messages", "pending_message_data"),
    ("orphan_message_store", "orphan_content"),
    ("orphan_message_store", "orphan_message_stanza"),
    ("ai_thread_info", "mode_metadata"),
    ("ZWAZACCOUNT", "ZADDITIONALDATA"),
    // Page-level statistics per table: no content, but they size what is blocked above.
    ("dbstat", nil),
]

/// `SQLITE_READ` is action 20; arguments 1 and 2 are the table and column. A bare C
/// function with no captured state, as SQLite requires.
private let authorizeRead:
    @convention(c) (
        UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
        UnsafePointer<CChar>?, UnsafePointer<CChar>?
    ) -> Int32 = { _, action, tableName, columnName, _, _ in
        guard action == SQLITE_READ, let tableName else { return SQLITE_OK }
        let table = String(cString: tableName)
        let column = columnName.map { String(cString: $0) }
        let blocked = blockedReads.contains { rule in
            (rule.table == "*" || rule.table.caseInsensitiveCompare(table) == .orderedSame)
                && (rule.column == nil
                    || rule.column?.caseInsensitiveCompare(column ?? "") == .orderedSame)
        }
        return blocked ? SQLITE_DENY : SQLITE_OK
    }
