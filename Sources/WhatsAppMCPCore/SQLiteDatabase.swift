import Foundation
import SQLite3

/// A read-only connection to a SQLite file.
///
/// SQLite comes from the system module macOS already ships. There is no package here for
/// the same reason there is no argument parser: a dependency has to earn its place, and
/// `import SQLite3` does this job in one import.
///
/// The connection is opened with `mode=ro&immutable=1`, and both halves matter:
///
/// - `mode=ro` refuses every write at the SQLite level rather than by convention. This
///   server reads someone's live chat history, and "we never call UPDATE" is a promise
///   the code makes to itself; a read-only handle is one the library enforces.
/// - `immutable=1` tells SQLite the file cannot change underneath it, so it takes no
///   locks, creates no `-shm`, and never touches the `-wal`. Without it, merely reading
///   WhatsApp's database writes to its sidecar files and can block the app itself.
///
/// The cost of `immutable=1` is real and is reported rather than hidden: messages sitting
/// in the write-ahead log that WhatsApp has not yet checkpointed are invisible here.
/// `whatsapp_status` says so whenever a non-empty `-wal` is present.
final class ReadOnlyDatabase {
    private let handle: OpaquePointer

    /// A failure to open, kept separate from `ToolError` so this file has no opinion
    /// about how the problem should be explained.
    struct OpenFailure: Error {
        let code: Int32
        let detail: String
    }

    struct QueryFailure: Error {
        let sql: String
        let detail: String
    }

    /// `file:` URI with the path percent-encoded, because the query string after `?` is
    /// how the read-only and immutable flags are set at all. A raw path would be taken
    /// literally and the flags would silently not apply.
    static func uri(for path: String) -> String {
        let encoded =
            path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return "file:\(encoded)?mode=ro&immutable=1"
    }

    init(path: String) throws {
        var connection: OpaquePointer?
        // FULLMUTEX because a connection is short-lived here but the MCP server is
        // asynchronous, and a serialised handle costs nothing measurable on a read.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(Self.uri(for: path), &connection, flags, nil)
        guard code == SQLITE_OK, let connection else {
            let detail =
                connection.map { String(cString: sqlite3_errmsg($0)) }
                ?? String(cString: sqlite3_errstr(code))
            if let connection { sqlite3_close_v2(connection) }
            throw OpenFailure(code: code, detail: detail)
        }
        handle = connection

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
            throw QueryFailure(sql: sql, detail: detail)
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
                throw QueryFailure(sql: sql, detail: String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    /// One row, valid only for the duration of the callback that receives it.
    struct Row {
        let statement: OpaquePointer

        func text(_ index: Int32) -> String? {
            guard let pointer = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: pointer)
        }

        func int(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }

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
