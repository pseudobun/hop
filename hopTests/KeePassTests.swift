import Foundation
import Testing
@testable import hop

struct TOTPTests {
    static let sha1Secret = Data("12345678901234567890".utf8)
    static let sha256Secret = Data("12345678901234567890123456789012".utf8)
    static let sha512Secret = Data("1234567890123456789012345678901234567890123456789012345678901234".utf8)

    /// RFC 6238 Appendix B.
    @Test(arguments: [
        (59.0, "94287082", "46119246", "90693936"),
        (1_111_111_109, "07081804", "68084774", "25091201"),
        (1_111_111_111, "14050471", "67062674", "99943326"),
        (1_234_567_890, "89005924", "91819424", "93441116"),
        (2_000_000_000, "69279037", "90698825", "38618901"),
        (20_000_000_000, "65353130", "77737706", "47863826"),
    ])
    func rfc6238(_ t: Double, _ sha1: String, _ sha256: String, _ sha512: String) {
        let date = Date(timeIntervalSince1970: t)
        #expect(TOTP.generate(.init(secret: Self.sha1Secret, digits: 8, algorithm: .sha1), at: date) == sha1)
        #expect(TOTP.generate(.init(secret: Self.sha256Secret, digits: 8, algorithm: .sha256), at: date) == sha256)
        #expect(TOTP.generate(.init(secret: Self.sha512Secret, digits: 8, algorithm: .sha512), at: date) == sha512)
    }

    @Test func otpauthURI() throws {
        let secret = Base32.encode(Self.sha1Secret)
        let uri = "otpauth://totp/Example:me?secret=\(secret)&issuer=Example&digits=8&period=30&algorithm=SHA1"
        #expect(try TOTP.code(uri, at: Date(timeIntervalSince1970: 59)) == "94287082")
        let six = "otpauth://totp/x?secret=\(secret)"
        #expect(try TOTP.code(six, at: Date(timeIntervalSince1970: 59)) == "287082")
    }

    @Test func keeOTPAndBareSecret() throws {
        let secret = Base32.encode(Self.sha1Secret)
        #expect(try TOTP.code("key=\(secret)&step=30&size=8", at: Date(timeIntervalSince1970: 59)) == "94287082")
        #expect(try TOTP.code(secret.lowercased(), at: Date(timeIntervalSince1970: 59)) == "287082")
        #expect(throws: (any Error).self) { try TOTP.code("not base32 !!") }
    }

    @Test(arguments: [("", ""), ("f", "MY======"), ("fo", "MZXQ===="), ("foo", "MZXW6==="),
                      ("foob", "MZXW6YQ="), ("fooba", "MZXW6YTB"), ("foobar", "MZXW6YTBOI======")])
    func base32(_ plain: String, _ encoded: String) throws {
        #expect(Base32.encode(Data(plain.utf8)) == encoded)
        #expect(try Base32.decode(encoded) == Data(plain.utf8))
    }
}

struct KeePassCSVTests {
    static let csv = """
    "Group","Title","Username","Password","URL","Notes","TOTP","Icon","Last Modified","Created"
    "Root","GitHub","bunny","  pa,ss"" word ","https://github.com","line one
    line two","otpauth://totp/GitHub?secret=GEZDGNBVGY3TQOJQ","0","2026-01-01T00:00:00Z","2026-01-01T00:00:00Z"
    "Root/Work","Linear","me@work","x","https://linear.app","","","0","",""
    "Root/Recycle Bin","Old","old","x","","","","0","",""
    "Root/Work/Deprecated","Older","old","x","","","","0","",""
    "Root","","nameless","x","","","","0","",""
    "Root","Bank","","x","","","","0","",""
    "Root","Bank","alice","y","","","","0","",""
    """

    @Test func parsesFiltersAndSorts() {
        let e = KeePassCSV.parse(Self.csv)
        #expect(e.map(\.title) == ["Bank", "Bank", "GitHub", "Linear"])
        #expect(e[0].username == "alice") // empty usernames last
        let gh = e[2]
        #expect(gh.group == "")
        #expect(gh.password == "  pa,ss\" word ")
        #expect(gh.notes == "line one\nline two")
        #expect(gh.totp.hasPrefix("otpauth://"))
        #expect(e[3].group == "Work")
        #expect(KeePassCSV.folders(e) == ["Work"])
    }

    @Test func placeholders() {
        let e = KeePassEntry(group: "", title: "T", username: "u", password: "p", url: "https://x", notes: "n",
                             totp: "otpauth://totp/x?secret=" + Base32.encode(TOTPTests.sha1Secret))
        let at = Date(timeIntervalSince1970: 59)
        #expect(KeePassPlaceholders.resolve("{USERNAME}:{password}@{URL} {TOTP} {X} {", e, now: at) == "u:p@https://x 287082 {X} {")
        #expect(KeePassPlaceholders.resolve("{PASSWORD}", KeePassEntry(group: "", title: "", username: "", password: "{USERNAME}",
                                                                        url: "", notes: "", totp: "")) == "{USERNAME}")
    }
}

struct KeePassCLITests {
    static let fake = Fixtures.directory.appending(path: "fake-keepassxc-cli.sh").path

    static func config() throws -> HopConfig.KeePass.Database {
        let db = FileManager.default.temporaryDirectory.appending(path: "hop-test.kdbx")
        try Data("not really".utf8).write(to: db)
        return HopConfig.KeePass.Database(name: "Test", path: db.path)
    }

    @Test func exportWithPasswordOnStdin() async throws {
        let entries = try await KeePassCLI.export(cli: Self.fake, database: try Self.config(), password: "secret")
        #expect(entries.map(\.title) == ["GitHub"])
        #expect(entries[0].password == "hunter2")
    }

    @Test func wrongPassword() async throws {
        await #expect(throws: KeePassError.invalidCredentials) {
            try await KeePassCLI.export(cli: Self.fake, database: try Self.config(), password: "nope")
        }
    }

    @Test func missingDatabase() async {
        let c = HopConfig.KeePass.Database(path: "/nonexistent/x.kdbx")
        await #expect(throws: KeePassError.databaseMissing) {
            try await KeePassCLI.export(cli: Self.fake, database: c, password: "secret")
        }
    }

    @Test func arguments() {
        #expect(KeePassCLI.arguments("export", database: "/d.kdbx", keyFile: "", noPassword: false, extra: ["-f", "csv"])
                == ["export", "-q", "-f", "csv", "/d.kdbx"])
        #expect(KeePassCLI.arguments("db-info", database: "/d.kdbx", keyFile: "/k", noPassword: true)
                == ["db-info", "-q", "-k", "/k", "--no-password", "/d.kdbx"])
    }
}
