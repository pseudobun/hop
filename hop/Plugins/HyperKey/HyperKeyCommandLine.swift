import AppKit
import Carbon.HIToolbox
import EventKit

/// `hop` CLI commands of the HyperKey plugin.
extension HyperKeyPlugin {
    static var cli: [CLICommand] {
        [
            CLICommand(names: ["hyper"], usage: [
                "hyper status | map | unmap          Caps Lock → F20 key mapping (unmap after a crash)",
            ], run: CLI.hyper),
        ]
    }
}

extension CLI {
    static func hyper(_ a: Args) async -> Int32 {
        switch a.positional.first ?? "status" {
        case "status":
            let mapped = await HyperKeyMapping.current().contains {
                $0["HIDKeyboardModifierMappingSrc"] == HyperKeyMapping.capsLock && $0["HIDKeyboardModifierMappingDst"] == HyperKeyMapping.f20
            }
            let info: [String: Any] = ["enabledInConfig": AppSettings().data.hyperKey.enabled, "capsMappedToF20": mapped,
                                       "accessibility": AXIsProcessTrusted(), "secureInput": IsSecureEventInputEnabled()]
            if a.json { Output.json(info) } else { for (k, v) in info.sorted(by: { $0.key < $1.key }) { print("\(k): \(v)") } }
            return 0
        case "map":
            return await HyperKeyMapping.apply() ? 0 : Output.fail("hidutil failed")
        case "unmap":
            return await HyperKeyMapping.restore() ? 0 : Output.fail("hidutil failed")
        default:
            return Output.fail("usage: hop hyper status | map | unmap")
        }
    }
}
