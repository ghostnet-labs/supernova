import Foundation
import SQLite3

struct ProjectSummary: Identifiable, Equatable {
    var id: UUID
    var name: String
    var version: Int
    var updatedAt: Date
}

// SQLite and filesystem access are serialized away from the UI actor.
actor HardwareStore {
    private var db: OpaquePointer?
    let directory: URL
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["HARDWARE_PLANNER_DATA_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hardware Planner", isDirectory: true)
    }

    init(directory: URL = HardwareStore.defaultDirectory) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = directory.appendingPathComponent("projects.sqlite3")
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            throw HardwareError.database("Could not open Hardware Planner database.")
        }
        do {
            sqlite3_busy_timeout(db, 5000)
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else { throw HardwareError.database("Could not read database schema.") }
            let version = sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : -1
            sqlite3_finalize(statement)
            guard version >= 0 && version <= 1 else { throw HardwareError.database("Database schema is newer than this app. No changes were made.") }
            if version == 0 {
                let backupDirectory = directory.appendingPathComponent("Backups", isDirectory: true)
                try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
                try Self.backup(db, to: backupDirectory.appendingPathComponent("before-schema-1-\(UUID()).sqlite3"))
                let migration = """
                BEGIN IMMEDIATE;
                CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT NOT NULL, version INTEGER NOT NULL, updated REAL NOT NULL, document BLOB NOT NULL);
                CREATE TABLE history (project_id TEXT NOT NULL, version INTEGER NOT NULL, document BLOB NOT NULL, PRIMARY KEY(project_id, version));
                PRAGMA user_version=1;
                COMMIT;
                """
                guard sqlite3_exec(db, migration, nil, nil, nil) == SQLITE_OK else { throw HardwareError.database("Database migration failed; pre-migration backup was preserved.") }
            }
            guard sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;", nil, nil, nil) == SQLITE_OK else {
                throw HardwareError.database("Could not configure durable database writes.")
            }
        } catch { sqlite3_close(db); db = nil; throw error }
    }

    deinit { sqlite3_close(db) }

    private static func backup(_ source: OpaquePointer?, to destination: URL) throws {
        var target: OpaquePointer?
        guard sqlite3_open(destination.path, &target) == SQLITE_OK else {
            if let target { sqlite3_close(target) }
            throw HardwareError.database("Could not create database backup.")
        }
        defer { sqlite3_close(target) }
        guard let backup = sqlite3_backup_init(target, "main", source, "main") else { throw HardwareError.database("Could not initialize database backup.") }
        let status = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard status == SQLITE_DONE && finish == SQLITE_OK else { throw HardwareError.database("Database backup did not finish.") }
        guard sqlite3_exec(target, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else {
            throw HardwareError.database("Could not finalize a portable database backup.")
        }
    }

    func backup() throws -> URL {
        let folder = directory.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("hardware-\(UUID()).sqlite3")
        try Self.backup(db, to: destination)
        return destination
    }

    private func statement(_ sql: String) throws -> OpaquePointer {
        var value: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &value, nil) == SQLITE_OK, let value else {
            throw HardwareError.database(String(cString: sqlite3_errmsg(db)))
        }
        return value
    }
    private func bind(_ text: String, to statement: OpaquePointer, at index: Int32) {
        sqlite3_bind_text(statement, index, text, -1, transient)
    }
    private func bind(_ data: Data, to statement: OpaquePointer, at index: Int32) {
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
    }
    private func run(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw HardwareError.database(String(cString: sqlite3_errmsg(db))) }
    }
    private func finish(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw HardwareError.database(String(cString: sqlite3_errmsg(db))) }
    }

    func list() throws -> [ProjectSummary] {
        let query = try statement("SELECT id,name,version,updated FROM projects ORDER BY updated DESC")
        defer { sqlite3_finalize(query) }
        var values: [ProjectSummary] = []
        var status = sqlite3_step(query)
        while status == SQLITE_ROW {
            guard let id = UUID(uuidString: String(cString: sqlite3_column_text(query, 0))) else { throw HardwareError.database("Stored project ID is invalid.") }
            values.append(ProjectSummary(id: id, name: String(cString: sqlite3_column_text(query, 1)), version: Int(sqlite3_column_int64(query, 2)), updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(query, 3))))
            status = sqlite3_step(query)
        }
        guard status == SQLITE_DONE else { throw HardwareError.database("Could not finish reading projects.") }
        return values
    }

    func load(_ id: UUID, version: Int? = nil) throws -> HardwareProject? {
        let query = try statement(version == nil ? "SELECT document FROM projects WHERE id=?" : "SELECT document FROM history WHERE project_id=? AND version=?")
        defer { sqlite3_finalize(query) }
        bind(id.uuidString, to: query, at: 1)
        if let version { sqlite3_bind_int64(query, 2, Int64(version)) }
        let status = sqlite3_step(query)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(query, 0) else { throw HardwareError.database("Could not read project.") }
        return try ProjectFormat.decode(Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, 0))))
    }

    @discardableResult
    func save(_ draft: HardwareProject) throws -> HardwareProject {
        try ProjectFormat.validate(draft)
        try run("BEGIN IMMEDIATE")
        do {
            let previous = try load(draft.id)
            guard (previous?.version ?? 0) == draft.version else { throw HardwareError.conflict }
            if let previous { try ProjectFormat.validateRevisionHistory(draft, previous: previous) }
            var project = draft
            project.version += 1; project.updatedAt = Date()
            try persist(project)
            try run("COMMIT")
            return project
        } catch { try? run("ROLLBACK"); throw error }
    }

    private func persist(_ project: HardwareProject) throws {
            let document = try ProjectFormat.encode(project)
            guard document.count <= 50 * 1024 * 1024 else { throw HardwareError.invalid("Project exceeds 50 MB. Reduce attachments before saving.") }
            let write = try statement("INSERT OR REPLACE INTO projects(id,name,version,updated,document) VALUES(?,?,?,?,?)")
            defer { sqlite3_finalize(write) }
            bind(project.id.uuidString, to: write, at: 1); bind(project.name, to: write, at: 2)
            sqlite3_bind_int64(write, 3, Int64(project.version)); sqlite3_bind_double(write, 4, project.updatedAt.timeIntervalSince1970)
            bind(document, to: write, at: 5); try finish(write)
            let history = try statement("INSERT INTO history(project_id,version,document) VALUES(?,?,?)")
            defer { sqlite3_finalize(history) }
            bind(project.id.uuidString, to: history, at: 1); sqlite3_bind_int64(history, 2, Int64(project.version)); bind(document, to: history, at: 3)
            try finish(history)
            // The database is authoritative; these managed copies can be recreated from JSON.
            let folder = directory.appendingPathComponent("Attachments", isDirectory: true).appendingPathComponent(project.id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for attachment in project.attachments {
                try attachment.content.write(to: folder.appendingPathComponent(attachment.id.uuidString), options: .atomic)
            }
    }

    func importProject(_ data: Data) throws -> HardwareProject {
        let project = try ProjectFormat.decode(data)
        try run("BEGIN IMMEDIATE")
        do {
            guard try load(project.id) == nil else { throw HardwareError.invalid("This project already exists. Import into a separate data directory to inspect a backup without replacing current work.") }
            try persist(project)
            try run("COMMIT")
            return project
        } catch { try? run("ROLLBACK"); throw error }
    }
}
