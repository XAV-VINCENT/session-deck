import Foundation
import SwiftUI

/// Made-up profiles and sessions for `--demo` and the README pictures: no real data leaves the Mac.
enum DemoData {
    static func snapshot(now: Date = Date()) -> Snapshot {
        let instances = [
            instance("Claude", "Work", 0, pid: 101),
            instance("Claude-Personal", "Personal", 1, pid: 102),
            instance("Claude-Freelance", "Freelance", 2, pid: 103),
            instance("Claude-Lab", "Lab", 3, pid: nil),
        ]
        let current = SidebarGroup(id: "current", name: "Current", order: 0)
        let stuck = SidebarGroup(id: "stuck", name: "Stuck", order: 1)
        let later = SidebarGroup(id: "later", name: "Later", order: 2)

        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func pr(_ number: Int, _ repo: String, _ state: String) -> PullRequest {
            PullRequest(number: number, repo: "acme/\(repo)", url: URL(string: "https://github.com/acme/\(repo)/pull/\(number)"), state: state)
        }

        let sessions: [Session] = [
            session("w1", "Claude", "Payments: move to webhooks v2", "acme-api", "feat/webhooks-v2", ago(0.4), .running,
                    "Working… (last: replayed 1,200 webhook events, 0 dropped)", starred: true, prs: [pr(482, "acme-api", "OPEN")]),
            session("w2", "Claude", "Write the migration runbook", "acme-api", "feat/webhooks-v2", ago(18), .done,
                    "Runbook drafted in docs/payments/webhooks-v2.md", parent: "w1"),
            session("w3", "Claude", "Fix the flaky checkout e2e test", "acme-web", "fix/checkout-e2e", ago(3), .needsYou,
                    "Retry the cart badge wait 3 times, or mock the inventory call?", group: current, prs: [pr(1931, "acme-web", "OPEN")]),
            session("w4", "Claude", "Upgrade to React 19", "acme-web", "chore/react-19", ago(26), .review,
                    "CI running on #1928: 4 of 6 checks green", group: current, prs: [pr(1928, "acme-web", "OPEN"), pr(1902, "acme-web", "MERGED")]),
            session("w5", "Claude", "Dark mode for the settings page", "acme-web", "feat/settings-dark", ago(95), .done,
                    "Merged #1920 with before and after screenshots", group: current, prs: [pr(1920, "acme-web", "MERGED")]),
            session("w6", "Claude", "Memory leak in the export worker", "acme-worker", "fix/export-leak", ago(240), .error,
                    "Not enough free disk space to set up a worktree. Free up space and try again.", group: stuck),
            session("w7", "Claude", "Rate limits for the public API", "acme-api", nil, ago(60 * 26), .idle,
                    "Plan ready: token bucket per API key, Redis backed", group: later),
            session("w8", "Claude", "Old spike: GraphQL gateway", "acme-api", nil, ago(60 * 24 * 12), .idle, nil, group: later),

            session("p1", "Claude-Personal", "Blog: notes on SwiftUI panels", "blog", "draft/swiftui-panels", ago(1), .running,
                    "Working… (last: added the NSPanel section)"),
            session("p2", "Claude-Personal", "dotfiles: zsh starts in under 50 ms", "dotfiles", nil, ago(7), .needsYou,
                    "Run `time zsh -i -c exit` ten times and paste the numbers"),
            session("p3", "Claude-Personal", "Nightly backups for the home server", "homelab", nil, ago(60 * 5), .done,
                    "restic job verified: 3 snapshots, restore tested"),

            session("f1", "Claude-Freelance", "Client portal: invoice PDF layout", "portal", "feat/invoice-pdf", ago(12), .needsYou,
                    "Which logo should the invoice use, the SVG or the PNG?", prs: [pr(77, "portal", "OPEN")]),
            session("f2", "Claude-Freelance", "Landing page copy review", "portal-site", "copy/landing-v3", ago(44), .review,
                    "Preview deploy is up, waiting for the client's comments", prs: [pr(75, "portal-site", "OPEN")]),
            session("f3", "Claude-Freelance", "Stripe Tax for EU customers", "portal", nil, ago(60 * 30), .done,
                    "Tax IDs collected at checkout; invoices show VAT"),

            session("l1", "Claude-Lab", "Prototype: voice notes to tasks", "voice-tasks", nil, ago(60 * 50), .idle,
                    "Transcription runs offline; next: pull tasks out of it"),
        ]
        return Snapshot(instances: instances, sessions: sessions, scannedAt: now)
    }

    private static func instance(_ id: String, _ label: String, _ index: Int, pid: pid_t?) -> Instance {
        Instance(
            id: id,
            dataDir: URL(fileURLWithPath: "/tmp/\(id)"),
            label: label,
            accountUuid: nil,
            color: instancePalette[index % instancePalette.count],
            pid: pid
        )
    }

    private static func session(
        _ id: String, _ instance: String, _ title: String, _ project: String, _ branch: String?, _ last: Date,
        _ state: SessionState, _ detail: String?, starred: Bool = false, parent: String? = nil,
        group: SidebarGroup? = nil, prs: [PullRequest] = []
    ) -> Session {
        Session(
            id: "local_demo_\(id)",
            instanceId: instance,
            title: title,
            project: project,
            cwd: "/tmp/\(project)",
            branch: branch,
            lastActivity: last,
            detail: detail,
            state: state,
            liveStatus: state == .running ? "busy" : nil,
            isStarred: starred,
            parentId: parent.map { "local_demo_\($0)" },
            pullRequests: prs,
            group: group
        )
    }
}
