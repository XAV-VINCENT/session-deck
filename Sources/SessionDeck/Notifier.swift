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
    static func post(_ session: Session, instance: Instance?, kind: Kind) {
        sound(for: kind)
        guard isAvailable, systemNotificationsWork else { return }
        let content = UNMutableNotificationContent()
        content.title = session.title
        content.subtitle = [kind.label, instance?.label, session.project]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        if let detail = session.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
            content.body = detail
        }
        content.sound = .default
        content.threadIdentifier = session.id
        content.userInfo = ["sessionId": session.id]
        let request = UNNotificationRequest(identifier: "\(session.id)#\(kind.suffix)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { deckLog("notification not posted: \(error.localizedDescription)") }
        }
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

        guard !isAdHocSigned else {
            print("SKIP system notifications: this build is ad-hoc signed, which the notification daemon")
            print("SKIP   will not register. Sign it with a Developer ID to add Notification Centre entries")
            print("SKIP   that survive a locked screen; the banner and sound above work either way.")
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
