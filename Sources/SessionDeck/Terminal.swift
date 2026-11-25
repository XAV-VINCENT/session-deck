import AppKit
import Foundation

/// A Claude Code session started from a terminal (`claude` in Warp, Terminal, iTerm2, an editor...).
struct CLIInfo: Hashable {
    let sessionId: String
    let cwd: String
    /// The `claude` process while the session is open, nil once it exited.
    let pid: pid_t?
    /// The app hosting that process, such as `dev.warp.Warp-Stable`.
    let hostBundleId: String?

    var isOpen: Bool { pid != nil }
    var resumeCommand: String { "claude --resume \(sessionId)" }
}

extension Instance {
    static let cliId = "cli"
    var isTerminal: Bool { id == Self.cliId }
}

/// Reads terminal sessions: the live status files in `~/.claude/sessions` (entrypoint `cli`) and the
/// transcripts in `~/.claude/projects`, for titles, the last prompt and reply, the branch.
/// Runs on the store's scan queue; heads are parsed once, tails again only when a file changes.
final class CLIScanner {
    struct Live {
        let pid: pid_t
        let sessionId: String
        let cwd: String
        let name: String?
        let status: String
        let waitingFor: String?
        let updatedAt: Date
        let hostBundleId: String?
    }

    private struct Head {
        let entrypoint: String?
        let firstPrompt: String?
        let cwd: String?
    }

    private struct Tail {
        var customTitle: String?
        var aiTitle: String?
        var lastPrompt: String?
        var lastReply: String?
        var branch: String?
        var cwd: String?
    }

    private var heads: [String: (modified: Date, head: Head)] = [:]
    private var tails: [String: (modified: Date, tail: Tail)] = [:]
    private let home = FileManager.default.homeDirectoryForCurrentUser
    /// Closed sessions older than this are not read at all.
    private let maxAge: TimeInterval = 30 * 86_400

    static let openGroup = SidebarGroup(id: "cli-open", name: "Open in a terminal", order: 0)
    static let closedGroup = SidebarGroup(id: "cli-closed", name: "Closed", order: 1)

    /// Transcripts of terminal sessions found by the last walk of `~/.claude/projects`, by session id.
    private var transcripts: [String: URL] = [:]
    private var lastWalk = Date.distantPast
    private var walkedFor = Set<String>()

    /// The terminal sessions, newest first, and the terminal app that hosts the most recent open one.
    /// The projects folder is walked every 20 s (or when a new session opens); in between only the known
    /// transcripts are checked.
    func scan() -> (sessions: [Session], hostBundleId: String?) {
        let live = readLive()
        let now = Date()
        let newLive = Set(live.keys).subtracting(transcripts.keys).subtracting(walkedFor)
        if now.timeIntervalSince(lastWalk) > 20 || !newLive.isEmpty {
            transcripts = walk(now: now)
            lastWalk = now
            walkedFor.formUnion(newLive)
        }
        var sessions: [Session] = []
        for (sessionId, url) in transcripts {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let open = live[sessionId]
            guard open != nil || now.timeIntervalSince(modified) < maxAge else { continue }
            sessions.append(makeSession(sessionId, head: cachedHead(url, modified: modified), tail: cachedTail(url, modified: modified), live: open, modified: modified))
        }
        for (id, open) in live where transcripts[id] == nil {
            sessions.append(makeSession(id, head: Head(entrypoint: "cli", firstPrompt: nil, cwd: open.cwd), tail: Tail(), live: open, modified: open.updatedAt))
        }
        let host = live.values.max { $0.updatedAt < $1.updatedAt }?.hostBundleId
        return (sessions.sorted { $0.lastActivity > $1.lastActivity }, host)
    }

    private func walk(now: Date) -> [String: URL] {
        let projects = home.appendingPathComponent(".claude/projects")
        var found: [String: URL] = [:]
        for dir in (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? [] {
            let dirURL = projects.appendingPathComponent(dir)
            for file in (try? FileManager.default.contentsOfDirectory(atPath: dirURL.path)) ?? [] where file.hasSuffix(".jsonl") {
                let url = dirURL.appendingPathComponent(file)
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                guard now.timeIntervalSince(modified) < maxAge, Self.isTerminal(cachedHead(url, modified: modified).entrypoint) else { continue }
                found[String(file.dropLast(6))] = url
            }
        }
        return found
    }

    /// `cli`, and the editor integrations; not the desktop app, not headless `-p` runs (`sdk-*`).
    private static func isTerminal(_ entrypoint: String?) -> Bool {
        guard let entrypoint else { return false }
        return entrypoint == "cli" || (entrypoint.hasPrefix("claude-") && entrypoint != "claude-desktop")
    }

    private func readLive() -> [String: Live] {
        let dir = home.appendingPathComponent(".claude/sessions")
        var result: [String: Live] = [:]
        for file in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where file.hasSuffix(".json") {
            guard let json = readJSON(dir.appendingPathComponent(file)),
                  json["hostSessionId"] == nil,
                  (json["kind"] as? String ?? "interactive") == "interactive",
                  Self.isTerminal(json["entrypoint"] as? String),
                  let sessionId = json["sessionId"] as? String,
                  let pid = (json["pid"] as? NSNumber)?.int32Value,
                  kill(pid, 0) == 0 else { continue }
            let named = (json["nameSource"] as? String) == "user"
            result[sessionId] = Live(
                pid: pid,
                sessionId: sessionId,
                cwd: json["cwd"] as? String ?? home.path,
                name: named ? json["name"] as? String : nil,
                status: json["status"] as? String ?? "idle",
                waitingFor: json["waitingFor"] as? String,
                updatedAt: Date(millis: json["updatedAt"]) ?? .distantPast,
                hostBundleId: TerminalLauncher.hostApp(of: pid)?.bundleIdentifier
            )
        }
        return result
    }

    private func makeSession(_ id: String, head: Head, tail: Tail, live: Live?, modified: Date) -> Session {
        let cwd = live?.cwd ?? tail.cwd ?? head.cwd ?? home.path
        let state: SessionState
        let detail: String?
        switch live?.status {
        case "busy", "working", "running":
            state = .running
            detail = tail.lastPrompt.map { "Working… (you asked: \($0))" } ?? "Working…"
        case let status? where status != "idle":
            state = .needsYou
            detail = "Waiting for you: \(live?.waitingFor ?? status)"
        default:
            state = .idle
            detail = tail.lastReply ?? tail.lastPrompt.map { "You: \($0)" }
        }
        let title = tail.customTitle ?? tail.aiTitle ?? live?.name ?? head.firstPrompt ?? "New session"
        return Session(
            id: id,
            instanceId: Instance.cliId,
            title: title,
            project: Self.project(of: cwd, home: home.path),
            cwd: cwd,
            branch: tail.branch.flatMap { $0 == "HEAD" ? nil : $0 },
            lastActivity: max(modified, live?.updatedAt ?? .distantPast),
            detail: detail,
            state: state,
            liveStatus: live?.status,
            isStarred: false,
            parentId: nil,
            pullRequests: [],
            group: live == nil ? Self.closedGroup : Self.openGroup,
            cli: CLIInfo(sessionId: id, cwd: cwd, pid: live?.pid, hostBundleId: live?.hostBundleId)
        )
    }

    /// The repository name, also for a worktree under `<repo>/.claude/worktrees/<name>`.
    private static func project(of cwd: String, home: String) -> String {
        if cwd == home { return "~" }
        if let range = cwd.range(of: "/.claude/worktrees/") {
            return URL(fileURLWithPath: String(cwd[..<range.lowerBound])).lastPathComponent
        }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    // MARK: - Transcripts

    private func cachedHead(_ url: URL, modified: Date) -> Head {
        if let hit = heads[url.path], hit.head.entrypoint != nil || hit.modified == modified { return hit.head }
        var entrypoint: String?
        var prompt: String?
        var cwd: String?
        for line in Self.lines(of: url, fromEnd: false, limit: 96 * 1024) {
            entrypoint = entrypoint ?? line["entrypoint"] as? String
            cwd = cwd ?? line["cwd"] as? String
            if prompt == nil, line["type"] as? String == "user", line["isMeta"] as? Bool != true {
                prompt = Self.text(of: line["message"]).flatMap(Self.cleanPrompt)
            }
            if entrypoint != nil && prompt != nil { break }
        }
        let head = Head(entrypoint: entrypoint, firstPrompt: prompt.map { String($0.prefix(70)) }, cwd: cwd)
        // Without an entrypoint yet (a brand new transcript), it is read again once the file changes.
        heads[url.path] = (modified, head)
        return head
    }

    private func cachedTail(_ url: URL, modified: Date) -> Tail {
        if let hit = tails[url.path], hit.modified == modified { return hit.tail }
        var tail = tails[url.path]?.tail ?? Tail()
        for line in Self.lines(of: url, fromEnd: true, limit: 512 * 1024) {
            switch line["type"] as? String {
            case "custom-title": tail.customTitle = (line["customTitle"] as? String)?.nonEmpty ?? tail.customTitle
            case "ai-title": tail.aiTitle = (line["aiTitle"] as? String)?.nonEmpty ?? tail.aiTitle
            case "last-prompt": tail.lastPrompt = (line["lastPrompt"] as? String).flatMap(Self.cleanPrompt).map { String($0.prefix(120)) } ?? tail.lastPrompt
            case "assistant":
                if let reply = Self.text(of: line["message"])?.split(separator: "\n").first.map(String.init)?.nonEmpty {
                    tail.lastReply = String(reply.prefix(160))
                }
            default: break
            }
            tail.branch = line["gitBranch"] as? String ?? tail.branch
            tail.cwd = line["cwd"] as? String ?? tail.cwd
        }
        tails[url.path] = (modified, tail)
        return tail
    }

    /// The JSON lines in the first or last `limit` bytes (a cut first or last line is skipped).
    private static func lines(of url: URL, fromEnd: Bool, limit: Int) -> [[String: Any]] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = fromEnd && size > UInt64(limit) ? size - UInt64(limit) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.read(upToCount: limit) else { return [] }
        var chunks = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if start > 0, !chunks.isEmpty { chunks.removeFirst() }
        return chunks.compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
    }

    private static func text(of message: Any?) -> String? {
        guard let message = message as? [String: Any] else { return nil }
        if let text = message["content"] as? String { return text }
        let blocks = message["content"] as? [[String: Any]] ?? []
        return blocks.last { $0["type"] as? String == "text" }?["text"] as? String
    }

    /// Drops slash-command wrappers and other tool noise that is not what the user typed.
    private static func cleanPrompt(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<"), !trimmed.hasPrefix("Caveat:") else { return nil }
        return trimmed.replacingOccurrences(of: "\n", with: " ")
    }
}

/// Brings a terminal session back: the terminal tab when it is open, `claude --resume` when it is closed.
enum TerminalLauncher {
    /// `"warp"`, `"iterm"` or `"terminal"` from the config; otherwise the app that hosted the last open session.
    static var preferred: String?
    static var lastHostBundleId: String?

    static func open(_ cli: CLIInfo) {
        if let pid = cli.pid, kill(pid, 0) == 0 {
            focus(pid)
        } else {
            resume(cli)
        }
    }

    /// Fronts the terminal app hosting `pid`; Terminal and iTerm2 also select the tab by its tty.
    static func focus(_ pid: pid_t) {
        guard let app = hostApp(of: pid) else {
            deckLog("no terminal app found above pid \(pid)")
            return
        }
        let tty = ttyName(of: pid)
        deckLog("focus terminal session pid \(pid) in \(app.bundleIdentifier ?? "?") on \(tty ?? "no tty")")
        if let tty {
            switch app.bundleIdentifier {
            case "com.apple.Terminal":
                runAppleScript("""
                tell application "Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "/dev/\(tty)" then
                                set selected of t to true
                                set index of w to 1
                            end if
                        end repeat
                    end repeat
                end tell
                """)
            case "com.googlecode.iterm2":
                runAppleScript("""
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is "/dev/\(tty)" then
                                    select w
                                    select t
                                    select s
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
                """)
            default:
                break
            }
        }
        Opener.activate(app.processIdentifier)
    }

    static func resume(_ cli: CLIInfo) {
        let app = resumeApp()
        deckLog("resume \(cli.sessionId) in \(app) at \(cli.cwd)")
        switch app {
        case "warp":
            // Warp runs a command only from a saved tab config: write one, then open it by name.
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".warp/tab_configs")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let config = """
            name = "Resume Claude session (Session Deck)"

            [[panes]]
            id = "main"
            type = "terminal"
            directory = "\(tomlEscaped(cli.cwd))"
            commands = ["\(tomlEscaped(cli.resumeCommand))"]

            """
            try? config.write(to: dir.appendingPathComponent("session_deck_resume.toml"), atomically: true, encoding: .utf8)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSWorkspace.shared.open(URL(string: "warp://tab_config/session_deck_resume")!)
            }
        case "iterm":
            runAppleScript("""
            tell application "iTerm2"
                activate
                set w to (create window with default profile)
                tell current session of w to write text "\(appleScriptEscaped(shellLine(cli)))"
            end tell
            """)
        default:
            runAppleScript("""
            tell application "Terminal"
                activate
                do script "\(appleScriptEscaped(shellLine(cli)))"
            end tell
            """)
        }
    }

    private static func resumeApp() -> String {
        if let preferred = preferred?.lowercased() { return preferred }
        switch lastHostBundleId {
        case "dev.warp.Warp-Stable": return "warp"
        case "com.googlecode.iterm2": return "iterm"
        case "com.apple.Terminal": return "terminal"
        default: break
        }
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.warp.Warp-Stable") != nil { return "warp" }
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil { return "iterm" }
        return "terminal"
    }

    /// The terminal (or editor) app the user sees, walking up from the `claude` process.
    static func hostApp(of pid: pid_t) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<16 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
                return app
            }
            guard let parent = processInfo(current)?.kp_eproc.e_ppid, parent > 1 else { return nil }
            current = parent
        }
        return nil
    }

    static func ttyName(of pid: pid_t) -> String? {
        guard let device = processInfo(pid)?.kp_eproc.e_tdev, device != -1,
              let name = devname(device, S_IFCHR) else { return nil }
        return String(cString: name)
    }

    private static func processInfo(_ pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    private static func shellLine(_ cli: CLIInfo) -> String {
        "cd '\(cli.cwd.replacingOccurrences(of: "'", with: "'\\''"))' && \(cli.resumeCommand)"
    }

    private static func tomlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func appleScriptEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func runAppleScript(_ source: String) {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { deckLog("AppleScript failed: \(error)") }
    }
}
