import AppKit
import Combine
import Foundation
import SwiftUI

/// Reads every Claude Desktop profile on disk and the live CLI status files, every two seconds.
final class Store: ObservableObject {
    @Published private(set) var snapshot = Snapshot()
    @Published var showOlder = UserDefaults.standard.bool(forKey: "showOlder") {
        didSet { if !isDemo { UserDefaults.standard.set(showOlder, forKey: "showOlder") } }
    }
    /// Notify on the same two transitions the notch banner shows. On unless config.json or the menu says no.
    @Published var notifies = UserDefaults.standard.object(forKey: "notifies") as? Bool ?? true {
        didSet { if !isDemo { UserDefaults.standard.set(notifies, forKey: "notifies") } }
    }

    /// Made-up profiles and sessions (`--demo`, README pictures): nothing on disk is read.
    let isDemo: Bool

    init(demo: Bool = false) {
        isDemo = demo
        if demo { showOlder = false }
        TerminalLauncher.preferred = config.terminal
    }

    var recentDays: Int { config.recentDays ?? 7 }

    var hotkey: HotKeySpec? {
        let text = config.hotkey ?? HotKeySpec.defaultText
        return text.lowercased() == "none" ? nil : HotKeySpec(text)
    }

    /// What the deck lists and counts: sessions touched in the last `recentDays`, plus pinned and running ones.
    var current: [Session] {
        showOlder ? snapshot.sessions : snapshot.sessions.filter(isRecent)
    }

    func olderCount(of instanceId: String) -> Int {
        snapshot.sessions.filter { $0.instanceId == instanceId && !isRecent($0) }.count
    }

    private func isRecent(_ session: Session) -> Bool {
        session.isStarred || session.state == .running
            || session.lastActivity > Date().addingTimeInterval(-Double(recentDays) * 86_400)
    }

    /// A session left `running`, or newly needs the user.
    var onTransition: ((Session, Notifier.Kind) -> Void)?

    private(set) var config = DeckConfig.load() {
        didSet { TerminalLauncher.preferred = config.terminal }
    }
    private let queue = DispatchQueue(label: "session-deck.scan", qos: .utility)
    private var parsed: [String: (modified: Date, session: RawSession?)] = [:]
    private let cli = CLIScanner()
    private var previousStates: [String: SessionState] = [:]
    private var timer: Timer?
    private var scanning = false

    func start() {
        if isDemo {
            loadNow()
            timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.loadNow() }
            return
        }
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.scan() }
    }

    /// The shortcut may have changed.
    var onConfigReload: (() -> Void)?

    func reloadConfig() {
        config = DeckConfig.load()
        onConfigReload?()
        scan()
    }

    func scan() {
        if isDemo { return loadNow() }
        guard !scanning else { return }
        scanning = true
        let pids = Self.runningInstancePids()
        let config = self.config
        queue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.buildSnapshot(pids: pids, config: config)
            DispatchQueue.main.async {
                self.scanning = false
                self.publish(snapshot)
            }
        }
    }

    /// `--selftest-notify` drives the real transition test with two snapshots, so the path from a state
    /// change to a banner and a sound is checked without waiting for a session on disk to move.
    func replay(_ before: Snapshot, _ after: Snapshot) {
        snapshot = before
        previousStates = Dictionary(before.sessions.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a })
        publish(after)
    }

    private func publish(_ next: Snapshot) {
        let firstScan = snapshot.scannedAt == .distantPast
        for session in next.sessions where !firstScan {
            let before = previousStates[session.id]
            let leftRunning = before == .running && session.state != .running
            let newlyNeedsYou = before != nil && before != .needsYou && session.state == .needsYou
            // Needs-you wins when a run ends on a question, which is the common case: the banner and the
            // notification should both say what is wanted, not that something stopped.
            if newlyNeedsYou {
                onTransition?(session, .needsYou)
            } else if leftRunning {
                onTransition?(session, .finished)
            }
        }
        previousStates = Dictionary(next.sessions.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a })
        // An unchanged scan redraws nothing, except every 30 s so "3m ago" keeps moving.
        let unchanged = next.sessions == snapshot.sessions && next.instances == snapshot.instances
        guard !unchanged || next.scannedAt.timeIntervalSince(snapshot.scannedAt) > 30 else { return }
        snapshot = next
    }

    // MARK: - Running instances

    static let claudeBundleId = "com.anthropic.claudefordesktop"

    /// Profile directory name ("Claude", "Claude-Personal", ...) to the pid of its main process.
    static func runningInstancePids() -> [String: pid_t] {
        var result: [String: pid_t] = [:]
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == claudeBundleId {
            let pid = app.processIdentifier
            let dir = userDataDir(in: ProcessArgs.arguments(of: pid) ?? []).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Claude"
            if let existing = result[dir], existing < pid { continue }
            result[dir] = pid
        }
        return result
    }

    private static func userDataDir(in args: [String]) -> String? {
        for (index, arg) in args.enumerated() {
            if arg.hasPrefix("--user-data-dir=") { return String(arg.dropFirst("--user-data-dir=".count)) }
            if arg == "--user-data-dir", index + 1 < args.count { return args[index + 1] }
        }
        return nil
    }

    /// `SessionDeck --dump`: the same data as the deck, as text.
    func snapshotNow() -> Snapshot {
        isDemo ? DemoData.snapshot() : buildSnapshot(pids: Self.runningInstancePids(), config: config)
    }

    /// For `--render`: publish a scan synchronously.
    func loadNow() {
        snapshot = snapshotNow()
    }

    func dump() -> String {
        let snapshot = snapshotNow()
        var lines: [String] = []
        for instance in snapshot.instances {
            let sessions = snapshot.sessions.filter { $0.instanceId == instance.id }
            lines.append("== \(instance.label) [\(instance.id)] pid=\(instance.pid.map(String.init) ?? "-") account=\(instance.accountUuid ?? "?") sessions=\(sessions.count)")
            for session in sessions.sorted(by: { ($0.group?.order ?? 10_000, -$0.lastActivity.timeIntervalSince1970) < ($1.group?.order ?? 10_000, -$1.lastActivity.timeIntervalSince1970) }) {
                let group = session.isStarred ? "Pinned" : session.group?.name ?? "Sessions"
                let prs = session.pullRequests.prefix(3).map { "#\($0.number)" }.joined(separator: ",")
                lines.append("  [\(group)] \(session.state.label.padding(toLength: 9, withPad: " ", startingAt: 0)) \(session.lastActivity.compactAgo.padding(toLength: 4, withPad: " ", startingAt: 0)) \(session.parentId == nil ? "" : "↳ ")\(session.title) · \(session.project) \(prs) | \(session.detail ?? "")")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Scan (background queue)

    private func buildSnapshot(pids: [String: pid_t], config: DeckConfig) -> Snapshot {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: support.path)) ?? [])
            .filter { $0 == "Claude" || $0.hasPrefix("Claude-") }
            .filter { FileManager.default.fileExists(atPath: support.appendingPathComponent("\($0)/claude-code-sessions").path) }
            .filter { config.instances[$0]?.hidden != true }
            .sorted { lhs, rhs in
                let l = config.instances[lhs]?.order ?? (lhs == "Claude" ? -1 : 100)
                let r = config.instances[rhs]?.order ?? (rhs == "Claude" ? -1 : 100)
                return l == r ? lhs < rhs : l < r
            }

        let live = readLiveStatuses()
        var instances: [Instance] = []
        var sessions: [Session] = []
        var seenFiles = Set<String>()

        for (index, name) in names.enumerated() {
            let dir = support.appendingPathComponent(name)
            let account = (cachedJSON(dir.appendingPathComponent("config.json"))?["lastKnownAccountUuid"]) as? String
            let custom = config.instances[name]
            let instance = Instance(
                id: name,
                dataDir: dir,
                label: custom?.label ?? defaultLabel(for: name),
                accountUuid: account,
                color: custom?.color.flatMap(Color.init(hex:)) ?? instancePalette[index % instancePalette.count],
                pid: pids[name]
            )
            instances.append(instance)

            let sidebar = readSidebar(dir.appendingPathComponent("claude_desktop_config.json"))
            let sessionsRoot = dir.appendingPathComponent("claude-code-sessions")
            let accounts = account.map { [$0] } ?? ((try? FileManager.default.contentsOfDirectory(atPath: sessionsRoot.path)) ?? [])

            for acct in accounts {
                let acctDir = sessionsRoot.appendingPathComponent(acct)
                for org in (try? FileManager.default.contentsOfDirectory(atPath: acctDir.path)) ?? [] {
                    let orgDir = acctDir.appendingPathComponent(org)
                    let archived = readArchivedIds(orgDir)
                    let groups = sidebar["\(acct)/\(org)"]
                    for file in (try? FileManager.default.contentsOfDirectory(atPath: orgDir.path)) ?? [] {
                        guard file.hasPrefix("local_"), file.hasSuffix(".json") else { continue }
                        let id = String(file.dropLast(5))
                        guard !archived.contains(id) else { continue }
                        let url = orgDir.appendingPathComponent(file)
                        seenFiles.insert(url.path)
                        guard let raw = cachedParse(url), !raw.isArchived, !raw.isSideChat else { continue }
                        sessions.append(makeSession(raw, instance: name, live: live[raw.id], group: groups?.group(for: raw.id)))
                    }
                }
            }
        }
        parsed = parsed.filter { seenFiles.contains($0.key) }

        if config.instances[Instance.cliId]?.hidden != true {
            let terminal = cli.scan()
            if !terminal.sessions.isEmpty {
                let custom = config.instances[Instance.cliId]
                let openPid = terminal.sessions.first { $0.cli?.pid != nil }?.cli?.pid
                instances.append(Instance(
                    id: Instance.cliId,
                    dataDir: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude"),
                    label: custom?.label ?? "Terminal",
                    accountUuid: nil,
                    color: custom?.color.flatMap(Color.init(hex:)) ?? instancePalette[names.count % instancePalette.count],
                    pid: openPid,
                    symbol: "terminal.fill"
                ))
                sessions += terminal.sessions
            }
            if let host = terminal.hostBundleId {
                DispatchQueue.main.async { TerminalLauncher.lastHostBundleId = host }
            }
        }
        return Snapshot(instances: instances, sessions: sessions, scannedAt: Date())
    }

    private func defaultLabel(for dirName: String) -> String {
        dirName == "Claude" ? "Default" : String(dirName.dropFirst("Claude-".count))
    }

    private func cachedParse(_ url: URL) -> RawSession? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        if let hit = parsed[url.path], hit.modified == modified { return hit.session }
        let session = readJSON(url).flatMap(RawSession.init(json:))
        parsed[url.path] = (modified, session)
        return session
    }

    private func makeSession(_ raw: RawSession, instance: String, live: LiveStatus?, group: SidebarGroup?) -> Session {
        let state: SessionState
        var detail: String?
        switch live?.status {
        case "busy", "working", "running":
            state = .running
            detail = "Working…"
        case let status? where status != "idle":
            state = .needsYou
            detail = "Waiting for you: \(live?.waitingFor ?? status)"
        default:
            if raw.errorIsCurrent {
                state = .error
                detail = raw.errorText
            } else if raw.needsAction != nil || raw.statusCategory == "blocked" || raw.interrupted {
                state = .needsYou
                detail = raw.needsAction ?? raw.statusDetail
            } else if raw.statusCategory == "review_ready" {
                state = .review
            } else if raw.statusCategory == "completed" {
                state = .done
            } else {
                state = .idle
            }
        }
        if detail == nil || state == .running {
            let summary = raw.statusDetail ?? raw.wrapUp
            detail = state == .running ? (summary.map { "Working… (last: \($0))" } ?? "Working…") : summary
        }
        return Session(
            id: raw.id,
            instanceId: instance,
            title: raw.title,
            project: raw.project,
            cwd: raw.cwd,
            branch: raw.branch,
            lastActivity: max(raw.lastActivity, live?.updatedAt ?? .distantPast),
            detail: detail,
            state: state,
            liveStatus: live?.status,
            isStarred: raw.isStarred,
            parentId: raw.parentId,
            pullRequests: raw.pullRequests,
            group: group
        )
    }

    // MARK: - Files

    private struct LiveStatus {
        let status: String
        let waitingFor: String?
        let updatedAt: Date
    }

    /// `~/.claude/sessions/<pid>.json` is written by every running Claude Code process.
    private func readLiveStatuses() -> [String: LiveStatus] {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
        var result: [String: LiveStatus] = [:]
        for file in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where file.hasSuffix(".json") {
            guard let json = readJSON(dir.appendingPathComponent(file)),
                  let host = json["hostSessionId"] as? String,
                  let pid = (json["pid"] as? NSNumber)?.int32Value,
                  kill(pid, 0) == 0 else { continue }
            let updated = Date(millis: json["updatedAt"]) ?? .distantPast
            if let existing = result[host], existing.updatedAt > updated { continue }
            result[host] = LiveStatus(status: json["status"] as? String ?? "idle", waitingFor: json["waitingFor"] as? String, updatedAt: updated)
        }
        return result
    }

    /// Small files read on every scan (account, sidebar, archive list), parsed again only when they change.
    private var jsonCache: [String: (modified: Date, json: [String: Any]?)] = [:]

    private func cachedJSON(_ url: URL) -> [String: Any]? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        if let hit = jsonCache[url.path], hit.modified == modified { return hit.json }
        let json = readJSON(url)
        jsonCache[url.path] = (modified, json)
        return json
    }

    private func readArchivedIds(_ orgDir: URL) -> Set<String> {
        let ids = cachedJSON(orgDir.appendingPathComponent("archived-sessions.idx"))?["archived"] as? [String]
        return Set(ids ?? [])
    }

    private struct GroupScope {
        let groups: [String: SidebarGroup]
        let assignments: [String: String]

        func group(for sessionId: String) -> SidebarGroup? {
            assignments["code:\(sessionId)"].flatMap { groups[$0] }
        }
    }

    /// The user's own sidebar groups ("Current", "Later", ...) per `account/org`.
    private func readSidebar(_ url: URL) -> [String: GroupScope] {
        guard let prefs = (cachedJSON(url)?["preferences"] as? [String: Any])?["epitaxyPrefs"] as? [String: Any],
              let scopes = prefs["dframe-group-scopes"] as? [String: Any] else { return [:] }
        let sections = prefs["dframe-code-sections"] as? [String: Any] ?? [:]
        var result: [String: GroupScope] = [:]
        for (key, value) in scopes {
            guard let scope = value as? [String: Any] else { continue }
            let sectionOrder = ((sections[key] as? [String: Any])?["sections"] as? [[String: Any]] ?? [])
                .compactMap { $0["id"] as? String }
            var groups: [String: SidebarGroup] = [:]
            for (index, group) in (scope["groups"] as? [[String: Any]] ?? []).enumerated() {
                guard let id = group["id"] as? String, let name = group["name"] as? String else { continue }
                groups[id] = SidebarGroup(id: id, name: name, order: sectionOrder.firstIndex(of: id) ?? 1000 + index)
            }
            result[key] = GroupScope(groups: groups, assignments: scope["assignments"] as? [String: String] ?? [:])
        }
        return result
    }
}

/// The fields of a `local_<id>.json` session record that the deck shows.
struct RawSession {
    let id: String
    let title: String
    let cwd: String
    let project: String
    let branch: String?
    let lastActivity: Date
    let isArchived: Bool
    let isStarred: Bool
    let parentId: String?
    /// A "btw" side chat, hidden by the Claude sidebar unless it was turned into a full session.
    let isSideChat: Bool
    let statusCategory: String?
    let statusDetail: String?
    let needsAction: String?
    let interrupted: Bool
    let errorText: String?
    let errorIsCurrent: Bool
    let wrapUp: String?
    let pullRequests: [PullRequest]

    init?(json: [String: Any]) {
        guard let id = json["sessionId"] as? String else { return nil }
        self.id = id
        cwd = json["originCwd"] as? String ?? json["cwd"] as? String ?? ""
        let gitRoot = (json["gitAnchors"] as? [[String: Any]])?.first?["gitRoot"] as? String
        project = URL(fileURLWithPath: gitRoot ?? cwd).lastPathComponent
        title = (json["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled session"
        branch = json["branch"] as? String
        let lastActivity = Date(millis: json["lastActivityAt"]) ?? .distantPast
        self.lastActivity = lastActivity
        isArchived = json["isArchived"] as? Bool ?? false
        isStarred = json["isStarred"] as? Bool ?? false
        let spawnedFrom = json["spawnedFrom"] as? [String: Any]
        parentId = spawnedFrom?["sessionId"] as? String
        isSideChat = spawnedFrom?["btw"] as? Bool == true && json["btwLoweredFrom"] == nil

        let summary = json["postTurnSummary"] as? [String: Any]
        statusCategory = summary?["status_category"] as? String
        statusDetail = (summary?["status_detail"] as? String).nonEmpty
        needsAction = (summary?["needs_action"] as? String).nonEmpty
        interrupted = !(json["interruptedAwaitingPerson"] is NSNull) && json["interruptedAwaitingPerson"] != nil

        let errorText = (json["error"] as? String).nonEmpty
        self.errorText = errorText
        let errorAt = Date(millis: json["errorAt"])
        errorIsCurrent = errorText != nil && errorAt.map { $0.addingTimeInterval(5) >= lastActivity } == true

        let wrap = (json["turnWrapUp"] as? [String: Any])?["description"] as? String
        let report = (json["lastTurnReport"] as? String)?.components(separatedBy: "⏎").first
        wrapUp = (wrap ?? report)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty

        // A PR with neither flag is only the branch checked out in the folder (the same PR on every
        // session of a shared checkout): keep it only when the session works on a branch of its own.
        let candidates = (json["prs"] as? [[String: Any]] ?? []).filter { ($0["dismissed"] as? Bool) != true }
        let touched = candidates.filter { ($0["own"] as? Bool) == true || ($0["notOwnRead"] as? Bool) == true }
        pullRequests = (touched.isEmpty && branch != nil ? candidates : touched)
            .compactMap { pr in
                guard let number = (pr["prNumber"] as? NSNumber)?.intValue else { return nil }
                return PullRequest(
                    number: number,
                    repo: pr["repo"] as? String ?? "",
                    url: (pr["url"] as? String).flatMap(URL.init(string:)),
                    state: pr["state"] as? String ?? "OPEN"
                )
            }
            .sorted { ($0.state == "OPEN" ? 0 : 1, -$0.number) < ($1.state == "OPEN" ? 0 : 1, -$1.number) }
    }
}

func readJSON(_ url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

extension Date {
    init?(millis value: Any?) {
        guard let number = value as? NSNumber else { return nil }
        self.init(timeIntervalSince1970: number.doubleValue / 1000)
    }
}

extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

enum ProcessArgs {
    /// argv of another process of the same user, through `KERN_PROCARGS2`.
    static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var args: [String] = []
        var start = index
        while index < size, args.count < argc {
            if buffer[index] == 0 {
                args.append(String(decoding: buffer[start..<index], as: UTF8.self))
                start = index + 1
            }
            index += 1
        }
        return args
    }
}
