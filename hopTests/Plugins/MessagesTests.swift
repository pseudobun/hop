import Foundation
import SQLite3
import Testing
@testable import hop

struct MessagesTests {
    @Test func findsCodes() {
        #expect(MessageCodes.code(in: "Your verification code is 482913") == "482913")
        #expect(MessageCodes.code(in: "G-552019 is your Google verification code.") == "552019")
        #expect(MessageCodes.code(in: "Vaša koda za prijavo: 123-456") == "123456")
        #expect(MessageCodes.code(in: "Use 8841 as your PIN") == "8841")
        #expect(MessageCodes.code(in: "OTP 1234 for order 99887766 valid 10 min") == "1234")
        // Six digits wins over other lengths.
        #expect(MessageCodes.code(in: "Code 2024: your login code is 771204") == "771204")
    }

    @Test func ignoresMessagesWithoutCodes() {
        #expect(MessageCodes.code(in: "See you at 1830 tomorrow") == nil)
        #expect(MessageCodes.code(in: "Your code") == nil)
        #expect(MessageCodes.code(in: "Payment code: 1.250,00 EUR") == nil)
        #expect(MessageCodes.code(in: "Login from +38640123456") == nil)
        #expect(MessageCodes.code(in: "Your code arrives in 2025") == nil)
        #expect(MessageCodes.code(in: "Koda nakupa: 12,00 EUR, kartica ***3223") == nil)
    }

    @Test func readsAttributedBody() {
        let text = "Koda: 123456"
        var bytes = [UInt8]("\u{04}\u{0B}streamtyped".utf8) + Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2B]
        bytes += [UInt8(text.utf8.count)] + Array(text.utf8) + [0x86, 0x84]
        #expect(MessageCodes.bodyText(Data(bytes)) == text)

        let long = String(repeating: "a", count: 300)
        var big = Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2B, 0x81, 0x2C, 0x01] + Array(long.utf8)
        big += [0x86]
        #expect(MessageCodes.bodyText(Data(big)) == long)
        #expect(MessageCodes.bodyText(Data("nothing".utf8)) == nil)
    }

    @Test func readsADatabase() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "hop-messages-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        let now = Date()
        let t = MessageCodes.appleTime(now)
        let old = MessageCodes.appleTime(now.addingTimeInterval(-7200))
        let sql = """
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
            CREATE TABLE message (ROWID INTEGER PRIMARY KEY, date INTEGER, text TEXT, attributedBody BLOB, handle_id INTEGER, is_from_me INTEGER);
            INSERT INTO handle VALUES (1, 'Revolut');
            INSERT INTO message VALUES (1, \(t), 'Your Revolut code is 112233', NULL, 1, 0);
            INSERT INTO message VALUES (2, \(t - 1000), 'My code is 445566', NULL, 1, 1);
            INSERT INTO message VALUES (3, \(old), 'Old code 778899', NULL, 1, 0);
            INSERT INTO message VALUES (4, \(t - 2000), 'hello', NULL, 1, 0);
            """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let codes = try MessageCodes.read(since: now.addingTimeInterval(-3600), from: path).get()
        #expect(codes.map(\.code) == ["112233"])
        #expect(codes.first?.sender == "Revolut")
        #expect(abs((codes.first?.date ?? .distantPast).timeIntervalSince(now)) < 1)
        #expect(MessageCodes.read(since: now, from: "/nonexistent/chat.db") == .failure(.noAccess))
    }

    @Test func readsOnlyRowsAfterARowID() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "hop-messages-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let t = MessageCodes.appleTime(Date())
        #expect(sqlite3_exec(db, """
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
            CREATE TABLE message (ROWID INTEGER PRIMARY KEY, date INTEGER, text TEXT, attributedBody BLOB, handle_id INTEGER, is_from_me INTEGER);
            INSERT INTO handle VALUES (1, 'Revolut');
            INSERT INTO message VALUES (1, \(t), 'Your Revolut code is 112233', NULL, 1, 0);
            """, nil, nil, nil) == SQLITE_OK)

        // The baseline only learns where the table ends.
        #expect(MessageCodes.read(afterRowID: nil, from: path) == .success(.init(lastRowID: 1, codes: [])))
        #expect(MessageCodes.read(afterRowID: 1, from: path) == .success(.init(lastRowID: 1, codes: [])))

        #expect(sqlite3_exec(db, """
            INSERT INTO message VALUES (2, \(t), 'My code is 445566', NULL, 1, 1);
            INSERT INTO message VALUES (3, \(t), 'Your login code: 990011', NULL, 1, 0);
            INSERT INTO message VALUES (4, \(t), 'hello', NULL, 1, 0);
            """, nil, nil, nil) == SQLITE_OK)
        let batch = try MessageCodes.read(afterRowID: 1, from: path).get()
        #expect(batch.lastRowID == 4)
        #expect(batch.codes.map(\.code) == ["990011"] && batch.codes.first?.id == 3)
        // Only the row from me came in: no code, but the ROWID moves on.
        #expect(try MessageCodes.read(afterRowID: 3, from: path).get() == .init(lastRowID: 4, codes: []))
        #expect(MessageCodes.read(afterRowID: 0, from: "/nonexistent/chat.db") == .failure(.noAccess))
    }

    @Test func notifiesOnlyForFreshCodes() {
        let now = Date()
        func code(_ age: TimeInterval) -> MessageCode {
            MessageCode(id: 1, code: "482913", sender: "Revolut", text: "", date: now.addingTimeInterval(-age))
        }
        #expect(MessageCodes.isFresh(code(5), now: now))
        #expect(MessageCodes.isFresh(code(119), now: now))
        #expect(!MessageCodes.isFresh(code(121), now: now)) // synced in late from another device
        #expect(!MessageCodes.isFresh(code(-600), now: now))
        #expect(MessageCodes.isFresh(code(-10), now: now)) // a little clock skew

        #expect(MessageCodeWatcher.message(for: code(0), pasteHotkey: "alt+cmd+v", copied: false) == "482913 · Revolut — ⌥⌘V to paste")
        #expect(MessageCodeWatcher.message(for: code(0), pasteHotkey: "", copied: true) == "482913 · Revolut — copied")
        #expect(MessageCodeWatcher.message(for: code(0), pasteHotkey: "", copied: false) == "482913 · Revolut")
        #expect(HotkeySpec.glyphs("cmd+shift+ctrl+space") == "⌃⇧⌘Space")
        #expect(HotkeySpec.glyphs("hyper+m") == "⌃⌥⇧⌘M")
        #expect(HotkeySpec.glyphs("nope") == nil)
    }

    @Test func configDefaults() throws {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        let config = try decoder.decode(HopConfig.self, from: Data("{messages: {autoCopy: true, pasteHotkey: \"\"}}".utf8))
        #expect(config.messages.autoCopy && config.messages.pasteHotkey.isEmpty && config.messages.notify && config.messages.days == 3)
        let defaults = HopConfig.Messages()
        #expect(defaults.notify && !defaults.autoCopy && defaults.pasteHotkey == "alt+cmd+v")
        #expect(try decoder.decode(HopConfig.self, from: Data(AppSettings.template.utf8)).messages == defaults)
    }
}
