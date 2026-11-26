import AppKit
import Security
import UserNotifications

/// macOS notifications for the two transitions the store already watches: a session that stopped running,
/// and one that started waiting for an answer.
///
/// The notch banner covers the same two events, but only for six seconds and only if you are looking at
/// that screen. These survive a full-screen app, another Space, and being away from the desk — they make a
/// sound and stay in Notification Centre until dismissed.
enum Notifier {
    enum Kind {
        case finished
        case needsYou

        var label: String { self == .finished ? "Finished" : "Needs you" }
        var suffix: String { self == .finished ? "finished" : "needs-you" }
    }

    /// `UNUserNotificationCenter.current()` traps in a process with no bundle, which is how the binary runs
    /// straight out of `.build` (`--dump`, `--selftest-notch`). Everything here is a no-op there.
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    private static let delegate = NotificationDelegate()

    // MARK: - A durable entry without a signature

    /// How long without a keypress or a mouse move counts as away from the desk.
    static let awaySeconds: Double = 60

    /// The notch banner lasts six seconds and leaves nothing behind, so an alert that fires while nobody
    /// is looking is simply lost — which is the whole reason to want Notification Centre. This app cannot
    /// register with it unsigned, but `osascript` is Apple-signed and will post on our behalf. The entry
    /// is attributed to Script Editor and does nothing when clicked, so it stands in for the banner when
    /// the banner would have gone unseen, rather than replacing it. At the desk the banner already said
    /// it, and a second one in the corner is just noise.
    static func isAway(idleSeconds: Double, screenLocked: Bool) -> Bool {
        screenLocked || idleSeconds >= awaySeconds
    }

    /// Seconds since the last human input. Asked per event type, because `CGEventType` cannot be built
    /// from the catch-all "any input" constant in Swift — it is not one of the enum's cases.
    static var secondsIdle: Double {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown, .flagsChanged, .scrollWheel]
        return types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? 0
    }

    static var screenIsLocked: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return info["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Separate from the posting so the test can prove the text never reaches the script source.
    /// Everything a human wrote goes after `--`, where AppleScript reads it as data through `argv`.
    /// Interpolating a session title into the script instead is a syntax error the first time one holds
    /// a quote, and an injected command the first time one is written to be.
    static func osascriptArguments(title: String, subtitle: String, body: String) -> [String] {
        [
            "-e", "on run argv",
            "-e", "display notification (item 3 of argv) with title (item 1 of argv) subtitle (item 2 of argv)",
            "-e", "end run",
            "--", title, subtitle, body,
        ]
    }

    @discardableResult
    static func postThroughOSAScript(title: String, subtitle: String, body: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = osascriptArguments(title: title, subtitle: subtitle, body: body)
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch {
            deckLog("borrowed notification failed to run: \(error.localizedDescription)")
            return false
        }
        proc.waitUntilExit()
        if proc.terminationStatus != 0 { deckLog("borrowed notification exited \(proc.terminationStatus)") }
        return proc.terminationStatus == 0
    }

    /// No Team ID means ad-hoc or unsigned, and the notification daemon will not register such an app:
    /// `requestAuthorization` comes back "Notifications are not allowed for this application". Worth knowing
    /// up front, so the app stops asking every launch and says plainly which half of this feature it has.
    static let isAdHocSigned: Bool = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return true }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return true }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return true }
        return dict[kSecCodeInfoTeamIdentifier as String] == nil
    }()

    /// Set once the system answers. False until then, and false for good when it refuses — which is what an
    /// ad-hoc signed app gets ("Notifications are not allowed for this application"), so the sound below is
    /// the whole notification on an unsigned build, and steps aside the moment the app is signed properly.
    private(set) static var systemNotificationsWork = false

    /// Heard, not seen: the banner needs the right screen, and the point is the times you are not looking.
    /// Two sounds, because "it finished" and "it is waiting for you" deserve different reactions.
    static func sound(for kind: Kind) {
        guard !systemNotificationsWork else { return }
        NSSound(named: kind == .needsYou ? "Submarine" : "Glass")?.play()
    }

    /// Called once at launch. The first call shows the system's "allow notifications?" prompt; later calls
    /// return the standing answer without asking again.
    static func start(onOpen: @escaping (String) -> Void) {
        guard isAvailable else {
            deckLog("notifications unavailable: not running from an app bundle")
            return
        }
        delegate.onOpen = onOpen
        guard !isAdHocSigned else {
            // Asking anyway only logs the same refusal on every launch and leaves a denial on record.
            deckLog("system notifications need a signed build (this one is ad-hoc); using the banner and a sound")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            systemNotificationsWork = granted
            deckLog("notifications \(granted ? "allowed" : "refused")\(error.map { ": \($0.localizedDescription)" } ?? "")")
        }
    }

    /// One notification per session per kind: posting again with the same identifier replaces the earlier
    /// one, so a session that flips state repeatedly leaves one entry, not a column of them.
    /// Returns what it did, for the log: the caller adds the banner, which is the one part it owns.
    @discardableResult
    static func post(_ session: Session, instance: Instance?, kind: Kind) -> String {
        sound(for: kind)
        guard isAvailable else { return "sound" }
        let subtitle = [kind.label, instance?.label, session.project]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        let detail = session.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard systemNotificationsWork else {
            guard isAway(idleSeconds: secondsIdle, screenLocked: screenIsLocked) else { return "sound" }
            // Never empty: `display notification ""` posts a blank entry.
            let ok = postThroughOSAScript(title: session.title, subtitle: subtitle,
                                          body: detail.isEmpty ? kind.label : detail)
            return ok ? "sound + borrowed entry" : "sound (borrowed entry refused)"
        }
        let content = UNMutableNotificationContent()
        content.title = session.title
        content.subtitle = subtitle
        if !detail.isEmpty { content.body = detail }
        content.sound = .default
        content.threadIdentifier = session.id
        content.userInfo = ["sessionId": session.id]
        let request = UNNotificationRequest(identifier: "\(session.id)#\(kind.suffix)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { deckLog("notification not posted: \(error.localizedDescription)") }
        }
        return "notification"
    }
}

extension Session {
    /// The same session in another state. Only the self-test needs it: a scan builds these from disk.
    func withState(_ state: SessionState) -> Session {
        Session(id: id, instanceId: instanceId, title: title, project: project, cwd: cwd, branch: branch,
                lastActivity: lastActivity, detail: detail, state: state, liveStatus: liveStatus,
                isStarred: isStarred, parentId: parentId, pullRequests: pullRequests, group: group, cli: cli)
    }
}

/// Clicking a notification opens its session, the same as clicking its row in the deck.
private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((String) -> Void)?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let id = response.notification.request.content.userInfo["sessionId"] as? String {
            DispatchQueue.main.async { [onOpen] in onOpen?(id) }
        }
        completionHandler()
    }

    /// The app is an accessory and never frontmost, but say so explicitly rather than relying on that.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}

extension Notifier {
    /// `SessionDeck --selftest-notify`: posts both kinds and reads Notification Centre back, so a refused
    /// permission or an unregistered bundle fails loudly instead of going quiet in production.
    static func runSelfTest() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        var failures = 0
        func expect(_ label: String, _ ok: Bool, _ info: String = "") {
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL") \(label)\(info.isEmpty ? "" : ": \(info)")")
        }
        guard isAvailable else {
            print("FAIL not running from an app bundle: run ~/Applications/Session Deck.app/Contents/MacOS/SessionDeck --selftest-notify")
            exit(1)
        }
        // Half of this needs a signature; the transition wiring never does, so check that first and
        // separately — an unsigned build must still be told when a session finishes or asks for something.
        let demo = Store(demo: true)
        let base = DemoData.snapshot()
        guard let subject = base.sessions.first(where: { $0.state == .running }) else {
            print("FAIL demo data has no running session"); exit(1)
        }
        func snapshot(_ state: SessionState) -> Snapshot {
            var copy = base
            copy.sessions = base.sessions.map { $0.id == subject.id ? $0.withState(state) : $0 }
            copy.scannedAt = Date()
            return copy
        }
        var seen: [(String, Kind)] = []
        demo.onTransition = { session, kind in seen.append((session.id, kind)) }
        // One state per scan, so a hold that lasts a scan is visible. The alerts come back as the
        // strings a reader can check against the state sequence: "needs-you", "finished", or none.
        func check(_ label: String, _ states: [SessionState], _ want: String) {
            seen = []
            demo.replay(states.map(snapshot))
            let got = seen.map { $0.1.suffix }.joined(separator: ",")
            let mine = seen.allSatisfy { $0.0 == subject.id }
            expect(label, got == want && mine, got.isEmpty ? "nothing fired" : got)
        }
        check("a run that ends reports finished, one scan later", [.running, .done, .done], "finished")
        // The regression: these two arrive on separate scans, and alerting on each gave two sounds.
        check("a run that ends on a question reports only needs-you", [.running, .done, .needsYou], "needs-you")
        check("a question is never held back", [.running, .needsYou], "needs-you")
        check("a run that pauses and resumes reports nothing", [.running, .done, .running], "")
        check("a session that did not move reports nothing", [.idle, .idle], "")
        expect("both alert sounds exist",
               NSSound(named: "Submarine") != nil && NSSound(named: "Glass") != nil,
               "Submarine and Glass")

        // A session title is whatever someone typed at Claude, so it reaches AppleScript as data or not
        // at all. This title carries the two things that break an interpolated script — a quote and a
        // backslash — and a command to run if the quoting ever fails open.
        let hostile = #"He said "hi" \ then: quit application "Finder""#
        let args = osascriptArguments(title: hostile, subtitle: "Needs you", body: hostile)
        let fragments = args.indices.filter { args[$0] == "-e" && $0 + 1 < args.count }.map { args[$0 + 1] }
        let data = args.firstIndex(of: "--").map { Array(args[($0 + 1)...]) } ?? []
        expect("a hostile title never reaches the script source",
               fragments.allSatisfy { !$0.contains("quit application") } && data.contains(hostile),
               "\(fragments.count) script fragments, \(data.count) arguments after --")
        // Both report what happened rather than what should have: a FAIL whose evidence line reads like
        // a PASS is the same trap in miniature.
        let posted = postThroughOSAScript(title: "Session Deck self-test", subtitle: "Needs you", body: hostile)
        expect("the borrowed entry posts, hostile text and all", posted,
               posted ? "osascript exited 0" : "osascript would not run the script")
        let gate = [isAway(idleSeconds: 0, screenLocked: false),
                    isAway(idleSeconds: awaySeconds - 1, screenLocked: false),
                    isAway(idleSeconds: awaySeconds, screenLocked: false),
                    isAway(idleSeconds: 0, screenLocked: true)]
        expect("away means a locked screen or a quiet minute", gate == [false, false, true, true],
               "0 s, 59 s, 60 s, locked -> " + gate.map { $0 ? "away" : "here" }.joined(separator: ", "))
        expect("the idle clock reads", secondsIdle >= 0 && secondsIdle.isFinite,
               String(format: "%.0f s since the last keypress or mouse move", secondsIdle))

        guard !isAdHocSigned else {
            print("SKIP system notifications: this build is ad-hoc signed, which the notification daemon")
            print("SKIP   will not register. Alerts are the banner and a sound, plus an entry borrowed")
            print("SKIP   through osascript while you are away from the desk. Sign it with a Developer ID")
            print("SKIP   for entries of this app's own, at any time, that open the session when clicked.")
            print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        let sample = base.sessions
        guard let finished = sample.first(where: { $0.state == .done }),
              let waiting = sample.first(where: { $0.state == .needsYou }) else {
            print("FAIL demo data has no done/needs-you session to post")
            exit(1)
        }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            DispatchQueue.main.async {
                expect("permission granted", granted, error?.localizedDescription ?? "")
                center.getNotificationSettings { settings in
                    DispatchQueue.main.async {
                        expect("notifications are enabled for this app",
                               settings.authorizationStatus == .authorized,
                               "\(settings.authorizationStatus.rawValue == 2 ? "authorized" : "status \(settings.authorizationStatus.rawValue)")")
                        post(finished, instance: nil, kind: .finished)
                        post(waiting, instance: nil, kind: .needsYou)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            center.getDeliveredNotifications { delivered in
                                DispatchQueue.main.async {
                                    let ids = Set(delivered.map(\.request.identifier))
                                    expect("the finished notification reached Notification Centre",
                                           ids.contains("\(finished.id)#finished"), finished.title)
                                    expect("the needs-you notification reached Notification Centre",
                                           ids.contains("\(waiting.id)#needs-you"), waiting.title)
                                    center.removeDeliveredNotifications(withIdentifiers: [
                                        "\(finished.id)#finished", "\(waiting.id)#needs-you",
                                    ])
                                    print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
                                    exit(failures == 0 ? 0 : 1)
                                }
                            }
                        }
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            print("FAIL timed out waiting for Notification Centre")
            exit(1)
        }
        app.run()
    }
}
