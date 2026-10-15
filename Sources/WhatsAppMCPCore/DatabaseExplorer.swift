import Foundation

/// A `db_query` answer: the rows plus which copy they came from, so a stale one is visible.
public struct QueryResult: Sendable, Equatable {
    public var columns: [String]
    public var rows: [[String]]
    public var truncated: Bool
    public var snapshot: SnapshotInfo
}

public struct TableEntry: Sendable, Equatable {
    public var name: String
    public var kind: String
}

/// The seam for `db_tables`, `db_schema` and `db_query`, kept apart from `WhatsAppStore`
/// because these three tools read any allowed database, not just the chat store, and
/// because the tests drive them with a fixture directory instead of a double.
public protocol DatabaseExplorer: Sendable {
    func tables(in database: AllowedDatabase) throws -> (entries: [TableEntry], snapshot: SnapshotInfo)
    func schema(of database: AllowedDatabase, table: String?) throws
        -> (statements: [String], snapshot: SnapshotInfo)
    func select(_ sql: String, in database: AllowedDatabase, limit: Int) throws -> QueryResult
    func existingSnapshots() -> [SnapshotInfo]
}

/// Reads only the cached copies. The source files are touched once per change, by
/// `SnapshotCache`; a query never opens a file in WhatsApp's container.
public struct SnapshotDatabaseExplorer: DatabaseExplorer {
    private let cache: SnapshotCache

    public init(cache: SnapshotCache) {
        self.cache = cache
    }

    public static let rowLimitRange = 1...500
    public static let defaultRowLimit = 100

    public func tables(in database: AllowedDatabase) throws -> (
        entries: [TableEntry], snapshot: SnapshotInfo
    ) {
        let (url, info) = try cache.snapshot(of: database)
        var entries: [TableEntry] = []
        try open(url).query(
            "SELECT name, type FROM sqlite_master WHERE type IN ('table', 'view') ORDER BY name"
        ) { row in
            entries.append(TableEntry(name: row.text(0) ?? "", kind: row.text(1) ?? ""))
        }
        return (entries, info)
    }

    public func schema(of database: AllowedDatabase, table: String?) throws -> (
        statements: [String], snapshot: SnapshotInfo
    ) {
        let (url, info) = try cache.snapshot(of: database)
        var statements: [String] = []
        // The table name is bound, never interpolated: it comes from the caller.
        try open(url).query(
            """
            SELECT sql FROM sqlite_master
            WHERE sql IS NOT NULL AND (?1 IS NULL OR tbl_name = ?1 COLLATE NOCASE)
            ORDER BY CASE type WHEN 'table' THEN 0 WHEN 'view' THEN 1 ELSE 2 END, name
            """,
            [table.map { .text($0) } ?? .null]
        ) { row in
            if let sql = row.text(0) { statements.append(sql) }
        }
        return (statements, info)
    }

    public func select(_ sql: String, in database: AllowedDatabase, limit: Int) throws
        -> QueryResult
    {
        let (url, info) = try cache.snapshot(of: database)
        let selected = try open(url).selectRows(sql, maxRows: limit)
        return QueryResult(
            columns: selected.columns, rows: selected.rows, truncated: selected.truncated,
            snapshot: info)
    }

    public func existingSnapshots() -> [SnapshotInfo] { cache.existingSnapshots() }

    private func open(_ url: URL) throws -> ReadOnlyDatabase {
        do {
            return try ReadOnlyDatabase(path: url.path)
        } catch let failure as ReadOnlyDatabase.OpenFailure {
            throw ToolError.storeFailure(failure.detail)
        }
    }
}
