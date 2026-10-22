import Foundation
import Testing
@testable import hop

struct SmokeTests {
    @Test func hostAppLoads() {
        #expect(Bundle.main.bundleIdentifier == "dev.hop.app")
    }
}
