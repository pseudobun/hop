import Foundation
import Testing
@testable import hop

struct HyperKeyMappingTests {
    @Test func parsesHidutilOutput() {
        let text = """
        (
                {
                HIDKeyboardModifierMappingDst = 30064771183;
                HIDKeyboardModifierMappingSrc = 30064771129;
            },
                {
                HIDKeyboardModifierMappingDst = 30064771300;
                HIDKeyboardModifierMappingSrc = 30064771301;
            }
        )
        """
        let entries = HyperKeyMapping.parse(text)
        #expect(entries.count == 2)
        #expect(entries[0]["HIDKeyboardModifierMappingSrc"] == HyperKeyMapping.capsLock)
        #expect(entries[0]["HIDKeyboardModifierMappingDst"] == HyperKeyMapping.f20)
        #expect(HyperKeyMapping.parse("(null)").isEmpty)
        #expect(HyperKeyMapping.json(entries).contains("\"HIDKeyboardModifierMappingSrc\":30064771129"))
    }
}

@MainActor
struct HyperKeyPluginTests {
    @Test func offByDefaultAndSwitchedByItsOwnKey() throws {
        let info = HyperKeyPlugin.info
        #expect(info.enabledPath == ["hyperKey", "enabled"] && !info.enabledByDefault)
        #expect(!info.isEnabled(in: HopConfig()))
        let d = JSONDecoder()
        d.allowsJSON5 = true
        let config = try d.decode(HopConfig.self, from: Data("{ hyperKey: { enabled: true, quickPressEscape: true } }".utf8))
        #expect(info.isEnabled(in: config) && config.hyperKey.quickPressEscape)
        #expect(BuiltinPlugins.needsAccessibility(config))
    }

    @Test func settingsAndCLI() {
        let keys = HyperKeyPlugin.settings.flatMap(\.rows).compactMap { if case .field(let f) = $0 { f.key } else { nil } }
        #expect(keys == ["hyperKey.enabled", "hyperKey.quickPressEscape"])
        #expect(HyperKeyPlugin.cli.map(\.names) == [["hyper"]])
        #expect(HyperKeyPlugin.cli[0].usage.first?.hasPrefix("hyper status") == true)
    }
}
