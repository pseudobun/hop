import Foundation
import Testing
@testable import hop

struct ConfigEnvTests {
    @Test func parsesDotenv() {
        let env = ConfigEnv.parse("""
        # hosts
        export DEN=https://den.example:18443
        LAN = "192.168.1.2"
        Q='a b'

        broken line
        """)
        #expect(env == ["DEN": "https://den.example:18443", "LAN": "192.168.1.2", "Q": "a b"])
    }

    @Test func expandsKnownAndReportsMissing() {
        let (text, missing) = ConfigEnv.expand(#"{ url: "${DEN}/tv", a: "${NOPE}", b: "$5 ${", c: "${A\"}" }"#,
                                               env: ["DEN": "https://d", "A\"": "x"])
        #expect(text == #"{ url: "https://d/tv", a: "${NOPE}", b: "$5 ${", c: "${A\"}" }"#)
        #expect(missing == ["NOPE"])
    }

    @Test func leavesCommentsAlone() {
        let (text, missing) = ConfigEnv.expand("""
        // ${NAME} comes from .env
        /* ${OTHER} */ { a: '${X}', b: "${X}" }
        """, env: ["X": "it's"])
        #expect(text == """
        // ${NAME} comes from .env
        /* ${OTHER} */ { a: 'it\\'s', b: "it's" }
        """)
        #expect(missing.isEmpty)
    }

    @Test func escapesValuesForJSON() throws {
        let (text, _) = ConfigEnv.expand(#"{ "p": "${P}" }"#, env: ["P": #"a"b\c"#])
        let decoded = try JSONDecoder().decode([String: String].self, from: Data(text.utf8))
        #expect(decoded["p"] == #"a"b\c"#)
    }

    @Test func readsDotenvBesideConfig() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hop-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "HOP_TEST_X=42\n".write(to: dir.appending(path: ".env"), atomically: true, encoding: .utf8)
        #expect(ConfigEnv.load(beside: dir.appending(path: "config.json5"))["HOP_TEST_X"] == "42")
    }
}
