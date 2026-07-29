import Foundation
import SQLite3

actor CopilotHistoryStore {
    nonisolated(unsafe) private var db: OpaquePointer?

    init(databaseURL: URL) {
        try? FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if sqlite3_open(databaseURL.path, &db) == SQLITE_OK {
            sqlite3_exec(db, """
                CREATE TABLE IF NOT EXISTS copilot_history (
                    id TEXT PRIMARY KEY,
                    created_at REAL NOT NULL,
                    question TEXT NOT NULL,
                    payload BLOB NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_copilot_history_created_at
                ON copilot_history(created_at DESC);
                """, nil, nil, nil)
        }
    }

    deinit { sqlite3_close(db) }

    func save(_ record: CopilotHistoryRecord) {
        guard let db, let payload = try? JSONEncoder.history.encode(record) else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT OR REPLACE INTO copilot_history(id, created_at, question, payload) VALUES(?, ?, ?, ?)",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, record.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(statement, 2, record.createdAt.timeIntervalSince1970)
        sqlite3_bind_text(statement, 3, record.question, -1, SQLITE_TRANSIENT)
        _ = payload.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 4, bytes.baseAddress, Int32(payload.count), SQLITE_TRANSIENT)
        }
        sqlite3_step(statement)
    }

    func recent(limit: Int = 100) -> [CopilotHistoryRecord] {
        loadRecent(limit: limit, includeLegacyCustomerRecords: false)
    }

    /// Legacy customer-Copilot payloads remain readable for migration and
    /// deletion, but are intentionally excluded from interview history.
    func recentIncludingLegacy(limit: Int = 100) -> [CopilotHistoryRecord] {
        loadRecent(limit: limit, includeLegacyCustomerRecords: true)
    }

    private func loadRecent(
        limit: Int,
        includeLegacyCustomerRecords: Bool
    ) -> [CopilotHistoryRecord] {
        guard let db else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT payload FROM copilot_history ORDER BY created_at DESC",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        let targetCount = max(1, limit)
        var records: [CopilotHistoryRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
            let length = Int(sqlite3_column_bytes(statement, 0))
            let data = Data(bytes: bytes, count: length)
            if let record = try? JSONDecoder.history.decode(CopilotHistoryRecord.self, from: data) {
                guard includeLegacyCustomerRecords || record.isInterviewRecord else { continue }
                records.append(record)
                if records.count == targetCount { break }
            }
        }
        return records
    }

    func deleteAll() {
        guard let db else { return }
        sqlite3_exec(db, "DELETE FROM copilot_history", nil, nil, nil)
    }

    func delete(sessionID: String) {
        guard let db else { return }
        let records = recentIncludingLegacy(limit: 10_000).filter { $0.sessionID == sessionID }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM copilot_history WHERE id = ?", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        for record in records {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, record.id.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_step(statement)
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private extension JSONEncoder {
    static var history: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var history: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
