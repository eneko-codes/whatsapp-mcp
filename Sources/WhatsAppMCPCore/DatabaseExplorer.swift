import Foundation

/// A `db_query` answer: the rows plus which source they were read from and when.
public struct QueryResult: Sendable, Equatable {
    public var columns: [String]
    public var rows: [[String]]
    public var truncated: Bool
    public var source: SourceInfo
}

public struct TableEntry: Sendable, Equatable {
    public var name: String
    public var kind: String
}

/// The seam for `db_tables`, `db_schema` and `db_query`, kept apart from `WhatsAppStore`
/// because these three tools read any allowed database, not just the chat store, and
/// because the tests drive them with a fixture directory instead of a double.
public protocol DatabaseExplorer: Sendable {
    func tables(in database: AllowedDatabase) throws -> (entries: [TableEntry], source: SourceInfo)
    func schema(of database: AllowedDatabase, table: String?) throws
        -> (statements: [String], source: SourceInfo)
    func select(_ sql: String, in database: AllowedDatabase, limit: Int) throws -> QueryResult
}

/// Reads the allow-listed databases live, through `ContainerDatabases`. `db_query` is the
/// one place a string from outside reaches SQLite, so it is the one place `ReadOnlyDatabase`
/// restricts what a statement may read to the tables the database itself declares.
public struct LiveDatabaseExplorer: DatabaseExplorer {
    private let databases: ContainerDatabases

    public init(databases: ContainerDatabases) {
        self.databases = databases
    }

    public static let rowLimitRange = 1...500
    public static let defaultRowLimit = 100

    public func tables(in database: AllowedDatabase) throws -> (
        entries: [TableEntry], source: SourceInfo
    ) {
        let (connection, info) = try databases.open(database)
        var entries: [TableEntry] = []
        try connection.query(
            "SELECT name, type FROM sqlite_master WHERE type IN ('table', 'view') ORDER BY name"
        ) { row in
            entries.append(TableEntry(name: row.text(0) ?? "", kind: row.text(1) ?? ""))
        }
        return (entries, info)
    }

    public func schema(of database: AllowedDatabase, table: String?) throws -> (
        statements: [String], source: SourceInfo
    ) {
        let (connection, info) = try databases.open(database)
        var statements: [String] = []
        // The table name is bound, never interpolated: it comes from the caller.
        try connection.query(
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
        let (connection, info) = try databases.open(database)
        let selected = try connection.selectRows(sql, maxRows: limit)
        return QueryResult(
            columns: selected.columns, rows: selected.rows, truncated: selected.truncated,
            source: info)
    }

}
