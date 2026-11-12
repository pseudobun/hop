import AppKit
import Testing
@testable import hop

@MainActor
struct LauncherSelectionTests {
    final class ListMode: Mode {
        let title: String? = "List"
        let placeholder = ""
        func sections(for query: String) -> [ResultSection] {
            [ResultSection(title: nil, items: ["a", "b", "c"].map { Item(id: $0, title: $0, actions: []) })]
        }
    }

    private func pressDown(_ launcher: LauncherController) {
        let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                    windowNumber: launcher.panel.windowNumber, context: nil, characters: "\u{F701}",
                                    charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125)!
        _ = launcher.panel.keyHandler?(down)
    }

    @Test func reopeningKeepsTheSelectedRow() {
        let launcher = LauncherController(root: ListMode())
        launcher.show()
        #expect(launcher.debugSelectedID == "a")
        pressDown(launcher)
        #expect(launcher.debugSelectedID == "b")
        launcher.hide()
        launcher.show()
        #expect(launcher.debugSelectedID == "b")
        launcher.hide()
    }

    @Test func popToRootStartsAtTheTopAgain() {
        let launcher = LauncherController(root: ListMode())
        launcher.popToRootSeconds = { -1 }
        launcher.show()
        pressDown(launcher)
        launcher.hide()
        launcher.show()
        #expect(launcher.debugSelectedID == "a")
        launcher.hide()
    }
}
