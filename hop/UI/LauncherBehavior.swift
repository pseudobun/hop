import Foundation

/// The launcher's reopen and key decisions, kept free of AppKit so they can be tested.
enum LauncherBehavior {
    enum Reopen: Equatable {
        /// Same mode, query and selected row.
        case restore
        /// Root search, but empty and at the top.
        case clearQuery
        /// Leave any sub-mode for an empty root search.
        case popToRoot
    }

    /// `popToRootSeconds` is "start over"; under it a sub-mode is always kept (a KeePassXC
    /// search), while the root query only lives `keepQueryFor` seconds (0 = never).
    static func reopen(elapsed: TimeInterval, inSubMode: Bool, keepQueryFor: Int, popToRootSeconds: Int) -> Reopen {
        if elapsed > Double(popToRootSeconds) { return .popToRoot }
        if inSubMode { return .restore }
        return keepQueryFor > 0 && elapsed <= Double(keepQueryFor) ? .restore : .clearQuery
    }

    enum Tab: Equatable {
        /// Replace the query with a completion (a path).
        case complete(String)
        /// Run the primary action: it enters a sub-mode.
        case enterMode
        case openActions
        case nothing
    }

    /// Completion wins, then an item that pushes a mode enters it; anything else with more
    /// than its ↵ action opens the action panel.
    static func tab(completion: String?, pushesMode: Bool, actionCount: Int) -> Tab {
        if let completion { return .complete(completion) }
        if pushesMode && actionCount > 0 { return .enterMode }
        return actionCount > 1 ? .openActions : .nothing
    }

    /// → opens the action panel only when it could not move the caret: nothing selected
    /// in the field and the caret after the last character.
    static func rightArrowOpensActions(selection: NSRange, textLength: Int, actionCount: Int) -> Bool {
        selection.length == 0 && selection.location >= textLength && actionCount > 1
    }
}
