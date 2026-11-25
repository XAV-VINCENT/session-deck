import Foundation
import SwiftUI

/// One Claude Desktop profile: `~/Library/Application Support/Claude` or `Claude-<Name>`.
struct Instance: Identifiable, Hashable {
    let id: String
    let dataDir: URL
    let label: String
    let accountUuid: String?
    let color: Color
    var pid: pid_t?
    /// An SF Symbol drawn instead of the label's initial (the Terminal card).
    var symbol: String?

    var isDefaultProfile: Bool { id == "Claude" }
    var isRunning: Bool { pid != nil }
}

enum SessionState: Int, CaseIterable {
    case needsYou, running, error, review, idle, done

    var label: String {
        switch self {
        case .needsYou: return "Needs you"
        case .running: return "Running"
        case .error: return "Error"
        case .review: return "Watching"
        case .idle: return "Idle"
        case .done: return "Done"
        }
    }

    var color: Color {
        switch self {
        case .needsYou: return Color(rgb: 0xFF9F0A)
        case .running: return Color(rgb: 0x40A0FF)
        case .error: return Color(rgb: 0xFF453A)
        case .review: return Color(rgb: 0xBF5AF2)
        case .idle: return Color.white.opacity(0.35)
        case .done: return Color(rgb: 0x30D158)
        }
    }

    /// The banner's first line when a session changes state.
    var headline: String {
        switch self {
        case .needsYou: return "Needs you"
        case .running: return "Running"
        case .error: return "Hit an error"
        case .review: return "Ready for review"
        case .idle, .done: return "Finished"
        }
    }

    var symbol: String {
        switch self {
        case .needsYou: return "exclamationmark.bubble.fill"
        case .running: return "circle.dotted"
        case .error: return "xmark.octagon.fill"
        case .review: return "eye.fill"
        case .idle: return "circle"
        case .done: return "checkmark.circle.fill"
        }
    }
}

struct PullRequest: Hashable {
    let number: Int
    let repo: String
    let url: URL?
    let state: String

    var color: Color {
        switch state {
        case "OPEN": return Color(rgb: 0x3FB950)
        case "MERGED": return Color(rgb: 0xA371F7)
        default: return Color(rgb: 0xF85149)
        }
    }
}

struct SidebarGroup: Hashable {
    let id: String
    let name: String
    let order: Int
}

struct Session: Identifiable, Hashable {
    let id: String
    let instanceId: String
    let title: String
    let project: String
    let cwd: String
    let branch: String?
    let lastActivity: Date
    let detail: String?
    let state: SessionState
    let liveStatus: String?
    let isStarred: Bool
    let parentId: String?
    let pullRequests: [PullRequest]
    let group: SidebarGroup?
    /// Set for sessions started from a terminal rather than the desktop app.
    var cli: CLIInfo?

    var deepLink: URL { URL(string: "claude://code/continue?session=\(id)")! }
}

/// Everything the views draw, rebuilt on every scan.
struct Snapshot {
    var instances: [Instance] = []
    var sessions: [Session] = []
    var scannedAt = Date.distantPast

    func count(_ state: SessionState) -> Int { sessions.filter { $0.state == state }.count }
    func instance(_ id: String) -> Instance? { instances.first { $0.id == id } }
}
