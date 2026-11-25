import AppKit
import CoreServices

/// Opens a session in the Claude Desktop profile that owns it.
///
/// Every profile runs the same bundle id, so `NSWorkspace.open(claude://...)` would land in
/// whichever instance Launch Services picks. Instead the `GURL` Apple Event goes to the pid of
/// the right instance, which hands it to its own `claude://code/continue?session=` handler.
enum Opener {
    static func open(_ session: Session, in instance: Instance) {
        if let cli = session.cli {
            TerminalLauncher.open(cli)
        } else {
            deliver(session.deepLink, to: instance)
        }
    }

    static func bringToFront(_ instance: Instance) {
        if instance.isTerminal {
            if let pid = instance.pid { TerminalLauncher.focus(pid) }
            return
        }
        if let pid = Store.runningInstancePids()[instance.id] {
            activate(pid)
        } else {
            launch(instance) { _ in }
        }
    }

    private static func deliver(_ url: URL, to instance: Instance) {
        guard let pid = Store.runningInstancePids()[instance.id] else {
            deckLog("open \(url.absoluteString): \(instance.id) not running, starting it")
            launch(instance) { pid in
                // A cold Electron start ignores links until its window is up: send once it should be, then once more.
                for delay in [6.0, 12.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { send(url, to: pid) }
                }
            }
            return
        }
        deckLog("open \(url.absoluteString) in \(instance.id) (pid \(pid))")
        send(url, to: pid)
        activate(pid)
    }

    /// Blocks until the event is handed over (or macOS asks the user for the Automation permission).
    static func sendGetURL(_ url: URL, to pid: pid_t) throws {
        let getURL = AEEventClass(0x4755_524C) // 'GURL'
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: getURL,
            eventID: AEEventID(getURL),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(string: url.absoluteString), forKeyword: AEKeyword(keyDirectObject))
        try event.sendEvent(options: [.noReply], timeout: 60)
    }

    private static func send(_ url: URL, to pid: pid_t) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try sendGetURL(url, to: pid)
            } catch {
                deckLog("Apple Event to pid \(pid) failed (\(error)); falling back to Launch Services")
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            }
        }
    }

    static func activate(_ pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.yieldActivation(to: app)
        app.activate(options: [.activateAllWindows])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            deckLog("activate pid \(pid): \(app.isActive ? "front" : "refused, using osascript")")
            guard !app.isActive else { return }
            // Same fallback the profile launchers use when cooperative activation is refused.
            let script = "ObjC.import('AppKit'); $.NSRunningApplication.runningApplicationWithProcessIdentifier(\(pid)).activateWithOptions(3)"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-l", "JavaScript", "-e", script]
            try? process.run()
        }
    }

    private static func launch(_ instance: Instance, then: @escaping (pid_t) -> Void) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Store.claudeBundleId) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.arguments = instance.isDefaultProfile ? [] : ["--user-data-dir=\(instance.dataDir.path)"]
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
            guard let app else {
                deckLog("could not start \(instance.id): \(String(describing: error))")
                return
            }
            DispatchQueue.main.async { then(app.processIdentifier) }
        }
    }
}
