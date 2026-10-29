import AppKit
import SQLite3

/// A verification code found in a received SMS or iMessage.
nonisolated struct MessageCode: Sendable, Equatable {
    let id: Int64
    let code: String
    let sender: String
    let text: String
    let date: Date
}

/// Reads one-time codes out of `~/Library/Messages/chat.db` (read only; needs Full Disk Access).
nonisolated enum MessageCodes {
    enum Failure: Error, Equatable { case noAccess, unreadable(String) }

    static var database: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Messages/chat.db")
    }

    /// One query at a time, off the Swift concurrency pool (SQLite blocks).
    private static let queue = DispatchQueue(label: "hop.messages", qos: .userInitiated)

    /// Codes received since `since`, newest first.
    static func recent(since: Date) async -> Result<[MessageCode], Failure> {
        await withCheckedContinuation { done in
            queue.async { done.resume(returning: read(since: since, from: database.path)) }
        }
    }

    /// Codes in rows after `rowID`, newest first, and the highest ROWID now in the table.
    nonisolated struct Batch: Sendable, Equatable {
        let lastRowID: Int64
        let codes: [MessageCode]
    }

    /// What arrived after `rowID`; with nil, only where the table ends now (the baseline).
    static func newer(than rowID: Int64?) async -> Result<Batch, Failure> {
        await withCheckedContinuation { done in
            queue.async { done.resume(returning: read(afterRowID: rowID, from: database.path)) }
        }
    }

    static func read(since: Date, from path: String) -> Result<[MessageCode], Failure> {
        withDatabase(path) { db in
            query(db, where: "m.date > ?", bind: appleTime(since))
        }
    }

    /// `SELECT MAX(ROWID)` first: Messages writes the WAL for read receipts, typing and sync
    /// far more often than a message arrives, and that check is one index lookup.
    static func read(afterRowID rowID: Int64?, from path: String) -> Result<Batch, Failure> {
        withDatabase(path) { db in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(ROWID), 0) FROM message", -1, &stmt, nil) == SQLITE_OK else {
                return .failure(failure(db))
            }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return .failure(failure(db)) }
            let last = sqlite3_column_int64(stmt, 0)
            guard let rowID, last > rowID else { return .success(Batch(lastRowID: last, codes: [])) }
            return query(db, where: "m.ROWID > ?", bind: rowID).map { Batch(lastRowID: last, codes: $0) }
        }
    }

    private static func withDatabase<T>(_ path: String, _ body: (OpaquePointer?) -> Result<T, Failure>) -> Result<T, Failure> {
        guard FileManager.default.isReadableFile(atPath: path) else { return .failure(.noAccess) }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return .failure(.unreadable(String(cString: sqlite3_errmsg(db))))
        }
        sqlite3_busy_timeout(db, 2000)
        return body(db)
    }

    private static func failure(_ db: OpaquePointer?) -> Failure {
        let message = String(cString: sqlite3_errmsg(db))
        return message.contains("authorization") ? .noAccess : .unreadable(message)
    }

    /// Received messages matching `condition` (one `?`, bound to `value`) that carry a code.
    private static func query(_ db: OpaquePointer?, where condition: String, bind value: Int64) -> Result<[MessageCode], Failure> {
        let sql = """
            SELECT m.ROWID, m.date, m.text, m.attributedBody, COALESCE(h.id, '')
            FROM message m LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE m.is_from_me = 0 AND \(condition)
            ORDER BY m.date DESC LIMIT 500
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return .failure(failure(db)) }
        sqlite3_bind_int64(stmt, 1, value)
        var codes: [MessageCode] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var text = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            if text.isEmpty, let blob = sqlite3_column_blob(stmt, 3) {
                let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 3)))
                text = bodyText(data) ?? ""
            }
            guard let code = code(in: text) else { continue }
            codes.append(MessageCode(id: sqlite3_column_int64(stmt, 0), code: code,
                                     sender: String(cString: sqlite3_column_text(stmt, 4)),
                                     text: text, date: date(appleTime: sqlite3_column_int64(stmt, 1))))
        }
        return .success(codes)
    }

    /// Worth a notification: received within `window` seconds (not an old row synced in late
    /// from another device, nor one dated far ahead by a skewed clock).
    static func isFresh(_ code: MessageCode, now: Date, window: TimeInterval = 120) -> Bool {
        let age = now.timeIntervalSince(code.date)
        return age <= window && age >= -60
    }

    // MARK: - Dates (nanoseconds since 2001; seconds in old databases)

    static func appleTime(_ date: Date) -> Int64 { Int64(date.timeIntervalSinceReferenceDate * 1_000_000_000) }

    static func date(appleTime t: Int64) -> Date {
        Date(timeIntervalSinceReferenceDate: t > 100_000_000_000 ? Double(t) / 1_000_000_000 : Double(t))
    }

    // MARK: - attributedBody

    /// The string inside an `attributedBody` typedstream (an archived NSAttributedString),
    /// where newer macOS keeps the text when `message.text` is empty.
    static func bodyText(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        let marker = Array("NSString".utf8)
        guard let start = bytes.indices.first(where: { bytes[$0...].starts(with: marker) }) else { return nil }
        // "NSString", then the class version and `+` (a C string follows): 01 94 84 01 2B.
        var i = start + marker.count
        guard let plus = bytes[i..<min(i + 8, bytes.count)].firstIndex(of: 0x2B) else { return nil }
        i = plus + 1
        guard i < bytes.count else { return nil }
        var length = Int(bytes[i])
        i += 1
        switch length {
        case 0x81: // 16-bit little-endian length
            guard i + 2 <= bytes.count else { return nil }
            length = Int(bytes[i]) | Int(bytes[i + 1]) << 8
            i += 2
        case 0x82: // 32-bit little-endian length
            guard i + 4 <= bytes.count else { return nil }
            length = (0..<4).reduce(0) { $0 | Int(bytes[i + $1]) << (8 * $1) }
            i += 4
        default: break
        }
        guard length > 0, i + length <= bytes.count else { return nil }
        return String(bytes: bytes[i..<(i + length)], encoding: .utf8)
    }

    // MARK: - Finding the code

    /// Words that mark a message as carrying a one-time code.
    private static let keywords = [
        "code", "kod", "otp", "verif", "passcode", "pin", "geslo", "2fa", "one-time", "one time",
        "einmal", "bestätigung", "token", "password", "potrd", "login", "sign in", "prijav",
    ]

    /// `G-123456`, `123-456`, `123 456` or 4–8 digits standing alone; not amounts, times or phone numbers.
    private static let candidate = try! NSRegularExpression(
        pattern: #"(?<![\w+\-.,:/*#])((?:[A-Z]-)?\d{3}[- ]\d{3}|(?:[A-Z]-)?\d{4,8})(?![\w\-]|[.,:/]\d)"#)

    /// The one-time code in a message, or nil when it doesn't look like one.
    static func code(in text: String) -> String? {
        let lower = text.lowercased()
        guard keywords.contains(where: lower.contains) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        let found = candidate.matches(in: text, range: range)
            .compactMap { Range($0.range(at: 1), in: text).map { digits(String(text[$0])) } }
            .filter { !isYear($0) }
        // Six digits is by far the most common length; otherwise the first one.
        return found.first { $0.count == 6 } ?? found.first
    }

    private static func digits(_ s: String) -> String { s.filter(\.isNumber) }

    private static func isYear(_ s: String) -> Bool {
        guard s.count == 4, let n = Int(s) else { return false }
        return (1990...2100).contains(n)
    }
}
