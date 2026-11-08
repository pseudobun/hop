import Foundation

/// How the session list is cut into sections (⌘⇧G), and the quick filters (⌘1…⌘9 the
/// environment, ⌥⌘1…⌥⌘4 the status, ⌘0 / ⌥⌘0 all), combined with the search field.
nonisolated enum AgentGrouping {
    enum GroupBy: String, CaseIterable, Sendable {
        case status, environment, project, provider

        var label: String {
            switch self {
            case .status: "Status"
            case .environment: "Environment"
            case .project: "Project"
            case .provider: "Provider"
            }
        }
    }

    struct Filter: Equatable, Sendable {
        /// "This Mac" or a host label; nil: every environment.
        var environment: String?
        var status: AgentStatus?

        var isEmpty: Bool { environment == nil && status == nil }

        /// For the count line: "olympus · Needs you".
        var label: String { [environment, status?.label].compactMap { $0 }.joined(separator: " · ") }

        func matches(_ s: AgentSession) -> Bool {
            (environment == nil || AgentGrouping.environment(s) == environment) && (status == nil || s.status == status)
        }
    }

    struct Section: Equatable, Sendable {
        var title: String
        var sessions: [AgentSession]
    }

    static let thisMac = "This Mac"

    static func environment(_ s: AgentSession) -> String { s.host ?? thisMac }

    /// The repository (or folder) a session works in: a hop worktree counts as its repository.
    static func project(_ s: AgentSession) -> String {
        let parts = s.cwd.split(separator: "/").map(String.init)
        if let i = parts.firstIndex(of: ".hop-worktrees"), i + 1 < parts.count { return parts[i + 1] }
        if let i = parts.firstIndex(of: ".worktrees"), i > 0 { return parts[i - 1] }
        return parts.last.map { $0 == "~" ? "Home" : $0 } ?? "Home"
    }

    /// This Mac, then the hosts as configured, then any other environment a session names.
    static func environments(hosts: [String], sessions: [AgentSession]) -> [String] {
        var out = [thisMac] + hosts.filter { $0 != thisMac }
        for s in sessions where !out.contains(environment(s)) { out.append(environment(s)) }
        return out
    }

    /// Sections in order; sessions keep their list order (`AgentSession.ordered`) inside each.
    static func sections(_ sessions: [AgentSession], by: GroupBy, hosts: [String] = []) -> [Section] {
        let sorted = sessions.sorted(by: AgentSession.ordered)
        func key(_ s: AgentSession) -> String {
            switch by {
            case .status: s.status.label
            case .environment: environment(s)
            case .project: project(s)
            case .provider: s.provider.label
            }
        }
        let order: [String] = switch by {
        case .status: [AgentStatus.waiting, .running, .idle, .finished].map(\.label)
        case .environment: environments(hosts: hosts, sessions: sorted)
        case .project: Set(sorted.map(project)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        case .provider: AgentProvider.allCases.map(\.label)
        }
        var groups: [String: [AgentSession]] = [:]
        for s in sorted { groups[key(s), default: []].append(s) }
        return order.compactMap { title in groups[title].map { Section(title: title, sessions: $0) } }
    }
}
