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
}
