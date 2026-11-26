import AppKit
import Combine
import ServiceManagement
import SwiftUI

@main
enum SessionDeckMain {
    private static var delegate: AppDelegate?

    static func main() {
        let args = CommandLine.arguments
        func value(after flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        if args.contains("--dump") {
            print(Store().dump())
            return
        }
        if let dir = value(after: "--render") {
            Render.run(into: URL(fileURLWithPath: dir))
            return
        }
        if let dir = value(after: "--render-assets") {
            Assets.run(into: URL(fileURLWithPath: dir))
            return
        }
        if let dir = value(after: "--render-animation") {
            Assets.renderAnimation(into: URL(fileURLWithPath: dir))
            return
        }
        if let id = value(after: "--open") {
            exit(openFromCommandLine(sessionId: id))
        }
        if let state = value(after: "--login-item") {
            exit(loginItemFromCommandLine(state))
        }
        if args.contains("--selftest-notch") {
            NotchController.runSelfTest()
        }
        if args.contains("--selftest-notify") {
            Notifier.runSelfTest()
        }
        let app = NSApplication.shared
        let delegate = AppDelegate(demo: args.contains("--demo"))
        Self.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// `SessionDeck --login-item on|off|status`: the same switch as "Open at login" in the menu.
private func loginItemFromCommandLine(_ state: String) -> Int32 {
    switch state {
    case "on", "off":
        let enabled = LoginItem.set(state == "on")
        print("Open at login: \(enabled ? "on" : "off") (\(SMAppService.mainApp.status.label))")
        return enabled == (state == "on") ? 0 : 1
    default:
        print("Open at login: \(LoginItem.isEnabled ? "on" : "off") (\(SMAppService.mainApp.status.label))")
        return 0
    }
}

extension SMAppService.Status {
    var label: String {
        switch self {
        case .enabled: return "enabled"
        case .notRegistered: return "not registered"
        case .requiresApproval: return "waiting for approval in System Settings > General > Login Items"
        case .notFound: return "not found"
        @unknown default: return "unknown"
        }
    }
}

/// `SessionDeck --open local_<id>`: sends the session's link to the instance that owns it, without
/// raising its window. Exit 0 once the event is delivered.
private func openFromCommandLine(sessionId: String) -> Int32 {
    let snapshot = Store().snapshotNow()
    guard let session = snapshot.sessions.first(where: { $0.id == sessionId }),
          let instance = snapshot.instance(session.instanceId) else {
        print("No open session \(sessionId)")
        return 2
    }
    if let cli = session.cli {
        // Terminal sessions only print what a click would do: focusing raises a window.
        if let pid = cli.pid {
            let app = TerminalLauncher.hostApp(of: pid)
            print("Open in \(app?.localizedName ?? "no terminal found") (pid \(app?.processIdentifier ?? 0)), claude pid \(pid) on \(TerminalLauncher.ttyName(of: pid) ?? "no tty")")
        } else {
            print("Closed: a click runs `\(cli.resumeCommand)` in \(cli.cwd)")
        }
        return 0
    }
    guard let pid = instance.pid else {
        print("\(instance.label) is not running")
        return 3
    }
    do {
        try Opener.sendGetURL(session.deepLink, to: pid)
        print("Sent \(session.deepLink) to \(instance.label) (pid \(pid))")
        return 0
    } catch {
        print("Apple Event failed: \(error)")
        return 1
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store: Store
    private let viewState: DeckViewState
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var notch: NotchController?
    private var hotKey: HotKey?
    private var keyMonitor: Any?
    private var subscriptions = Set<AnyCancellable>()
    private var makePopoverContent: (() -> NSViewController)?

    init(demo: Bool) {
        store = Store(demo: demo)
        viewState = DeckViewState(persist: !demo)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let actions = DeckActions(
            open: { [weak self] session in self?.open(session) },
            bringToFront: { [weak self] instance in
                self?.popover.performClose(nil)
                guard self?.store.isDemo == false else { return }
                Opener.bringToFront(instance)
            }
        )

        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self
        // The popover's deck is built when it opens and dropped when it closes, so it costs nothing while hidden.
        makePopoverContent = { [store, viewState] in
            NSHostingController(rootView: DashboardView(store: store, viewState: viewState, actions: actions)
                .frame(width: 640, height: 660)
                .background(Color.black))
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = MenuBarIcon.image
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        if store.config.notch != false {
            notch = NotchController(store: store, viewState: viewState, actions: actions)
        }
        store.onTransition = { [weak self] session, kind in
            guard let self else { return }
            self.notch?.peek(session)
            guard self.store.notifies else { return }
            deckLog("\(kind.suffix): \(session.title) — banner\(Notifier.systemNotificationsWork ? " + notification" : " + sound")")
            Notifier.post(session, instance: self.store.snapshot.instance(session.instanceId), kind: kind)
        }
        if store.config.notifications == false { store.notifies = false }
        Notifier.start { [weak self] id in
            guard let self, let session = self.store.snapshot.sessions.first(where: { $0.id == id }) else { return }
            self.open(session)
        }
        store.onConfigReload = { [weak self] in self?.registerHotKey() }
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusTitle() }
            .store(in: &subscriptions)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown, event.window === self.popover.contentViewController?.view.window else { return event }
            let used = DeckKeys.handle(event, store: self.store, viewState: self.viewState, open: { self.open($0) }, close: { self.popover.performClose(nil) })
            return used ? nil : event
        }
        registerHotKey()
        store.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let item = self?.statusItem else { return }
            deckLog("status item visible=\(item.isVisible) frame=\(String(describing: item.button?.window?.frame)) screen=\(item.button?.window?.screen?.localizedName ?? "none")")
        }
    }

    private func registerHotKey() {
        hotKey = nil
        guard let spec = store.hotkey else { return }
        hotKey = HotKey(spec) { [weak self] in
            guard let self else { return }
            if let notch = self.notch { notch.toggleFromKeyboard() } else { self.togglePopover() }
        }
    }

    private func open(_ session: Session) {
        popover.performClose(nil)
        viewState.selectedId = nil
        guard !store.isDemo else {
            deckLog("demo: would open \(session.title)")
            return
        }
        guard let instance = store.snapshot.instance(session.instanceId) else { return }
        Opener.open(session, in: instance)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController = makePopoverContent?()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.viewState.focusToken += 1 }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }

    /// Runs after the change lands (`receive(on:)` defers past `objectWillChange`).
    private func updateStatusTitle() {
        let current = store.current
        let running = current.filter { $0.state == .running }.count
        let needsYou = current.filter(DeckFilter.needsYou.admits).count
        let title = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        func part(_ count: Int, _ color: NSColor) {
            guard count > 0 else { return }
            title.append(NSAttributedString(string: " ●", attributes: [.foregroundColor: color, .font: NSFont.systemFont(ofSize: 9)]))
            title.append(NSAttributedString(string: "\(count)", attributes: [.font: font]))
        }
        part(running, NSColor(SessionState.running.color))
        part(needsYou, NSColor(SessionState.needsYou.color))
        statusItem.button?.attributedTitle = title
        statusItem.button?.toolTip = "\(running) running · \(needsYou) need you · \(current.count) recent sessions"
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns the state actually reached.
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            deckLog("login item change failed: \(error)")
        }
        return isEnabled
    }
}

enum MenuBarIcon {
    /// A screen outline with the deck hanging from its notch, drawn as a template so it follows the menu bar.
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 16), flipped: true) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let screen = NSBezierPath(roundedRect: NSRect(x: 1, y: 1.5, width: 16, height: 13), xRadius: 3, yRadius: 3)
            screen.lineWidth = 1.5
            screen.stroke()
            let deck = NSBezierPath(roundedRect: NSRect(x: 5, y: 1.5, width: 8, height: 6.5), xRadius: 2, yRadius: 2)
            deck.fill()
            NSBezierPath(rect: NSRect(x: 5, y: 1.5, width: 8, height: 2)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Claude sessions"
        return image
    }()
}
