import AppKit
import Carbon.HIToolbox
import EventKit

/// `hop` CLI commands of the Messages plugin.
extension MessagesPlugin {
    static var cli: [CLICommand] {
        [
            CLICommand(names: ["codes"], usage: [
                "codes [--latest] [--minutes=N] [--json]   One-time codes from Messages (needs Full Disk Access)",
            ], run: CLI.codes),
        ]
    }
}

extension CLI {
    /// `hop codes [--latest] [--minutes=N]`: one-time codes from Messages, newest first.
    static func codes(_ a: Args) async -> Int32 {
        let config = AppSettings().data.messages
        let latest = a.flags.contains("latest")
        let minutes = a.option("minutes").flatMap(Int.init) ?? (latest ? config.latestMinutes : config.days * 1440)
        switch await MessageCodes.recent(since: Date().addingTimeInterval(-Double(minutes) * 60)) {
        case .failure(.noAccess):
            return Output.fail("cannot read ~/Library/Messages: give the terminal (or hop) Full Disk Access")
        case .failure(.unreadable(let message)):
            return Output.fail("cannot read Messages: \(message)")
        case .success(let codes):
            let list = latest ? Array(codes.prefix(1)) : codes
            if latest && list.isEmpty { return Output.fail("no code in the last \(minutes) minutes") }
            if a.json {
                Output.json(list.map { ["code": $0.code, "sender": $0.sender, "date": iso.string(from: $0.date), "text": $0.text] })
            } else if latest {
                print(list[0].code)
            } else {
                for c in list { print("\(c.code)\t\(c.sender)\t\(iso.string(from: c.date))\t\(oneLine(c.text))") }
            }
            return 0
        }
    }
}
