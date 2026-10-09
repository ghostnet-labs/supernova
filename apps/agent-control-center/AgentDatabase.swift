import Foundation
import SQLite3

enum AgentStorageError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

/// A connection is only exposed inside the database actor's synchronous closures.
final class SQLiteConnection {
    private var handle: OpaquePointer?
    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            handle = nil
            throw AgentStorageError.invalid("Could not open the project database.")
        }
        sqlite3_busy_timeout(handle, 5_000)
    }
    deinit { sqlite3_close(handle) }

    func execute(_ sql: String, _ parameters: [String?] = []) throws {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }

    func query(_ sql: String, _ parameters: [String?] = []) throws -> [[String: String]] {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        var rows: [[String: String]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw error() }
            var row: [String: String] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                guard let value = sqlite3_column_text(statement, index) else { continue }
                row[String(cString: sqlite3_column_name(statement, index))] = String(decoding: UnsafeBufferPointer(start:value,count:Int(sqlite3_column_bytes(statement,index))),as:UTF8.self)
            }
            rows.append(row)
        }
    }

    func backup(to url: URL) throws {
        let destination = try SQLiteConnection(url: url)
        guard let backup = sqlite3_backup_init(destination.handle, "main", handle, "main") else { throw error() }
        let result = sqlite3_backup_step(backup, -1)
        let finished = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE && finished == SQLITE_OK else { throw error() }
    }

    private func prepare(_ sql: String, _ parameters: [String?]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        for (offset, value) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            if let value {
                result = value.withCString { sqlite3_bind_text(statement, index, $0, Int32(value.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            } else { result = sqlite3_bind_null(statement, index) }
            guard result == SQLITE_OK else { sqlite3_finalize(statement); throw error() }
        }
        return statement
    }
    private func error() -> AgentStorageError { .invalid(String(cString: sqlite3_errmsg(handle))) }
}

/// All app-owned writes are serialized here, independently of provider databases.
actor AgentDatabase {
    nonisolated let url: URL
    private let connection: SQLiteConnection
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.agent-control-center", isDirectory: true)
    }

    init(directory: URL = AgentDatabase.defaultDirectory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("projects.sqlite")
        let existed = FileManager.default.fileExists(atPath:url.path)
        connection = try SQLiteConnection(url: url)
        _ = try connection.query("PRAGMA journal_mode=WAL")
        try connection.execute("PRAGMA foreign_keys=ON")
        let version = Int(try connection.query("PRAGMA user_version").first?["user_version"] ?? "0") ?? 0
        guard version <= 1 else { throw AgentStorageError.invalid("This database requires a newer Agent Control Center.") }
        if version < 1 {
            if existed { try connection.backup(to: directory.appendingPathComponent("before-v1-\(UUID().uuidString).sqlite")) }
            try connection.execute("BEGIN IMMEDIATE")
            do {
                for statement in Self.schema { try connection.execute(statement) }
                try connection.execute("PRAGMA user_version=1")
                try connection.execute("COMMIT")
            } catch { try? connection.execute("ROLLBACK"); throw error }
        }
    }

    func read<T>(_ body: (SQLiteConnection) throws -> T) rethrows -> T { try body(connection) }
    func transaction<T>(_ body: (SQLiteConnection) throws -> T) throws -> T {
        try connection.execute("BEGIN IMMEDIATE")
        do { let value = try body(connection); try connection.execute("COMMIT"); return value }
        catch { try? connection.execute("ROLLBACK"); throw error }
    }
    func backup() throws -> URL {
        let destination = url.deletingLastPathComponent().appendingPathComponent("backup-\(UUID().uuidString).sqlite")
        try connection.backup(to: destination)
        return destination
    }

    private static let schema = [
        "CREATE TABLE projects(id TEXT PRIMARY KEY,name TEXT NOT NULL,scope TEXT NOT NULL,common_dir TEXT NOT NULL,cwd TEXT NOT NULL)",
        "CREATE UNIQUE INDEX project_repository_scope ON projects(scope,common_dir) WHERE common_dir<>''",
        "CREATE TABLE checkouts(path TEXT NOT NULL,scope TEXT NOT NULL,project_id TEXT NOT NULL REFERENCES projects(id),PRIMARY KEY(path,scope))",
        "CREATE TABLE sources(id TEXT PRIMARY KEY,project_id TEXT NOT NULL REFERENCES projects(id),provider TEXT NOT NULL,session_id TEXT NOT NULL,title TEXT NOT NULL,path TEXT NOT NULL,identity TEXT NOT NULL DEFAULT '',offset INTEGER NOT NULL DEFAULT 0,size INTEGER NOT NULL DEFAULT 0,modified TEXT NOT NULL DEFAULT '',checkpoint TEXT NOT NULL DEFAULT '',status TEXT NOT NULL DEFAULT 'Pending',skipped INTEGER NOT NULL DEFAULT 0,discarding INTEGER NOT NULL DEFAULT 0,UNIQUE(project_id,provider,session_id))",
        "CREATE TABLE messages(id TEXT PRIMARY KEY,source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,project_id TEXT NOT NULL REFERENCES projects(id),role TEXT NOT NULL,text TEXT NOT NULL,timestamp TEXT NOT NULL,native_id TEXT NOT NULL,offset INTEGER NOT NULL,length INTEGER NOT NULL,fingerprint TEXT NOT NULL,representation TEXT NOT NULL,original_url TEXT,valid INTEGER NOT NULL DEFAULT 1)",
        "CREATE INDEX messages_source ON messages(source_id,offset)",
        "CREATE VIRTUAL TABLE message_search USING fts5(text,content='messages',content_rowid='rowid',tokenize='unicode61')",
        "CREATE TRIGGER messages_insert AFTER INSERT ON messages BEGIN INSERT INTO message_search(rowid,text) VALUES(new.rowid,new.text); END",
        "CREATE TRIGGER messages_delete AFTER DELETE ON messages BEGIN INSERT INTO message_search(message_search,rowid,text) VALUES('delete',old.rowid,old.text); END",
        "CREATE TRIGGER messages_update AFTER UPDATE OF text ON messages BEGIN INSERT INTO message_search(message_search,rowid,text) VALUES('delete',old.rowid,old.text); INSERT INTO message_search(rowid,text) VALUES(new.rowid,new.text); END",
        "CREATE TABLE decisions(id TEXT PRIMARY KEY,project_id TEXT NOT NULL REFERENCES projects(id),json TEXT NOT NULL)",
        "CREATE TABLE decision_revisions(id INTEGER PRIMARY KEY,decision_id TEXT NOT NULL,json TEXT NOT NULL,created TEXT NOT NULL)",
        "CREATE TABLE managed_records(namespace TEXT NOT NULL,key TEXT NOT NULL,json TEXT NOT NULL,PRIMARY KEY(namespace,key))",
    ]
}
