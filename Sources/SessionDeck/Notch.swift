import AppKit
import Carbon.HIToolbox
import SwiftUI

final class NotchModel: ObservableObject {
    enum Mode: Equatable {
        case collapsed
        case peek(String)
        case expanded
    }

    @Published var mode: Mode = .collapsed
    @Published var notchSize = CGSize(width: 190, height: 32)

    static let wing: CGFloat = 40
    static let expandedSize = CGSize(width: 680, height: 620)
    static let peekSize = CGSize(width: 500, height: 74)

    var collapsedSize: CGSize {
        CGSize(width: notchSize.width + Self.wing * 2, height: notchSize.height)
    }

    var size: CGSize {
        switch mode {
        case .collapsed: return collapsedSize
        case .peek: return CGSize(width: max(collapsedSize.width, Self.peekSize.width), height: notchSize.height + Self.peekSize.height)
        case .expanded: return Self.expandedSize
        }
    }

    var cornerRadius: CGFloat {
        switch mode {
        case .collapsed: return 10
        case .peek: return 22
        case .expanded: return 28
        }
    }
}

private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The app is never active, so without this the first click on a row would only focus the panel.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A black pill around the camera notch (or a fake one at the top centre of a screen without one):
/// running count on the left, needs-you count on the right. Point at it, or press the shortcut,
/// to drop the full deck down.
final class NotchController {
    private let store: Store
    private let viewState: DeckViewState
    private let actions: DeckActions
    private let model = NotchModel()
    private let panel: NotchPanel
    private var hoverWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var monitors: [Any] = []
    private var pointerInside = false
    /// Opened with the shortcut: stays open until Escape, the shortcut again, a click outside or an open.
    private var openedByKeyboard = false
    /// Gets the keyboard back when the deck closes without opening anything.
    private var previousApp: NSRunningApplication?
    private static let margin: CGFloat = 28

    /// `watchesPointer: false` keeps the self-test away from the real mouse.
    init(store: Store, viewState: DeckViewState, actions: DeckActions, watchesPointer: Bool = true) {
        self.store = store
        self.viewState = viewState
        self.actions = actions
        panel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        var wrapped = actions
        wrapped.open = { [weak self] session in self?.open(session) }
        let host = FirstClickHostingView(rootView: NotchRootView(model: model, store: store, viewState: viewState, actions: wrapped))
        host.sizingOptions = []
        panel.contentView = host
        panel.acceptsMouseMovedEvents = true

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.placeOnScreen()
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, event.window === self.panel, self.handleKey(event) else { return event }
            return nil
        }) { monitors.append(monitor) }
        placeOnScreen()
        panel.orderFrontRegardless()
        guard watchesPointer else { return }
        // Pointer position, not SwiftUI hover: hover tracking can stay silent while this background app is inactive.
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
            self?.pointerMoved(to: NSEvent.mouseLocation)
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
            self?.pointerMoved(to: NSEvent.mouseLocation)
            return event
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            guard let self, self.model.mode != .collapsed else { return }
            self.collapse()
        }) { monitors.append(monitor) }
    }

    /// The shortcut: open the deck with the search field focused, or close it.
    func toggleFromKeyboard() {
        if model.mode == .expanded {
            collapse(restoreFocus: true)
            return
        }
        previousApp = NSWorkspace.shared.frontmostApplication
        openedByKeyboard = true
        expand()
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.viewState.focusToken += 1 }
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard model.mode == .expanded else { return false }
        return DeckKeys.handle(event, store: store, viewState: viewState, open: { [weak self] session in
            self?.open(session)
        }, close: { [weak self] in
            self?.collapse(restoreFocus: true)
        })
    }

    private func open(_ session: Session) {
        previousApp = nil
        actions.open(session)
        collapse()
    }

    /// The black shape on screen (it grows with the mode), plus the screen's top edge.
    private var hotRect: NSRect {
        guard let screen else { return .zero }
        let size = model.size
        return NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height + 2)
    }

    private func pointerMoved(to point: NSPoint) {
        let inside = hotRect.contains(point)
        guard inside != pointerInside else { return }
        pointerInside = inside
        hoverChanged(inside)
    }

    func peek(_ session: Session) {
        guard model.mode == .collapsed else { return }
        setFrame(for: .peek(session.id))
        withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) { model.mode = .peek(session.id) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.model.mode == .peek(session.id) else { return }
            self.collapse()
        }
    }

    private func hoverChanged(_ inside: Bool) {
        hoverWork?.cancel()
        if inside {
            collapseWork?.cancel()
            guard model.mode != .expanded else { return }
            let work = DispatchWorkItem { [weak self] in self?.expand() }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        } else if model.mode != .collapsed && !openedByKeyboard {
            let work = DispatchWorkItem { [weak self] in self?.collapse() }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
    }

    private func expand() {
        setFrame(for: .expanded)
        withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { model.mode = .expanded }
    }

    func collapse(restoreFocus: Bool = false) {
        collapseWork?.cancel()
        openedByKeyboard = false
        viewState.selectedId = nil
        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { model.mode = .collapsed }
        if panel.isKeyWindow {
            panel.resignKey()
            if restoreFocus { previousApp?.activate() }
        }
        previousApp = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.model.mode == .collapsed else { return }
            self.setFrame(for: .collapsed)
        }
    }

    private var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func placeOnScreen() {
        guard let screen else { return }
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            model.notchSize = CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
        } else {
            model.notchSize = CGSize(width: 150, height: NSStatusBar.system.thickness)
        }
        setFrame(for: model.mode)
    }

    private func setFrame(for mode: NotchModel.Mode) {
        guard let screen else { return }
        let probe = NotchModel()
        probe.notchSize = model.notchSize
        probe.mode = mode
        let margin = mode == .collapsed ? 0 : Self.margin
        let width = max(probe.size.width, model.size.width) + margin * 2
        let height = max(probe.size.height, model.size.height) + margin
        let frame = NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
        panel.setFrame(frame, display: true)
    }
}

struct NotchRootView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var store: Store
    @ObservedObject var viewState: DeckViewState
    let actions: DeckActions

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(radius: model.cornerRadius)
                    .fill(Color.black)
                    .shadow(color: .black.opacity(model.mode == .collapsed ? 0 : 0.55), radius: 22, y: 10)
                NotchRim(radius: model.cornerRadius)
                    .stroke(LinearGradient(colors: [.white.opacity(0), .white.opacity(0.14)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                    .opacity(model.mode == .collapsed ? 0 : 1)
                content
                    .clipShape(NotchShape(radius: model.cornerRadius))
            }
            .frame(width: model.size.width, height: model.size.height)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var content: some View {
        switch model.mode {
        case .collapsed:
            wings
                .transition(.opacity)
        case .peek(let id):
            VStack(spacing: 0) {
                wings
                if let session = store.snapshot.sessions.first(where: { $0.id == id }) {
                    PeekCard(session: session, instance: store.snapshot.instance(session.instanceId), onOpen: actions.open)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        case .expanded:
            DashboardView(store: store, viewState: viewState, actions: actions, notchSize: model.notchSize)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
        }
    }

    private var wings: some View {
        NotchWings(store: store, notchSize: model.notchSize)
    }
}

/// Running count left of the camera, needs-you count right of it (a green check when all is quiet).
struct NotchWings: View {
    @ObservedObject var store: Store
    let notchSize: CGSize

    var body: some View {
        let current = store.current
        let running = current.filter { $0.state == .running }.count
        let needsYou = current.filter(DeckFilter.needsYou.admits).count
        return HStack(spacing: 0) {
            HStack(spacing: 5) {
                if running > 0 {
                    GradientSpinner(color: SessionState.running.color, lineWidth: 2.2)
                        .frame(width: 14, height: 14)
                    Text(verbatim: "\(running)")
                        .contentTransition(.numericText())
                }
            }
            .frame(width: NotchModel.wing)
            Spacer(minLength: notchSize.width)
            HStack(spacing: 5) {
                if needsYou > 0 {
                    PulsingDot(color: SessionState.needsYou.color, size: 7)
                        .frame(width: 12, height: 12)
                    Text(verbatim: "\(needsYou)")
                        .contentTransition(.numericText())
                } else if running == 0 && !current.isEmpty {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(SessionState.done.color)
                }
            }
            .frame(width: NotchModel.wing)
        }
        .font(Theme.rounded(12.5, .bold))
        .monospacedDigit()
        .foregroundStyle(.white)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: running)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: needsYou)
        .frame(width: notchSize.width + NotchModel.wing * 2, height: notchSize.height)
        .frame(maxWidth: .infinity)
    }
}

extension NotchController {
    /// `SessionDeck --selftest-notch`: drives the real panel with pointer positions and keys (demo data), printing each check.
    static func runSelfTest() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let store = Store(demo: true)
        store.loadNow()
        let viewState = DeckViewState(persist: false)
        var opened: Session?
        let controller = NotchController(store: store, viewState: viewState, actions: DeckActions(open: { opened = $0 }, bringToFront: { _ in }), watchesPointer: false)
        guard let screen = controller.screen else { print("FAIL no screen"); exit(1) }
        let top = NSPoint(x: screen.frame.midX, y: screen.frame.maxY - 3)
        let insideDeck = NSPoint(x: screen.frame.midX + 200, y: screen.frame.maxY - 400)
        let away = NSPoint(x: screen.frame.minX + 40, y: screen.frame.midY)
        var failures = 0
        func expect(_ label: String, _ ok: Bool, _ info: String = "") {
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL") \(label)\(info.isEmpty ? "" : ": \(info)")")
        }
        func frame(_ label: String, width: CGFloat) {
            let frame = controller.panel.frame
            let ok = abs(frame.width - width) < 1 && abs(frame.maxY - screen.frame.maxY) < 1 && abs(frame.midX - screen.frame.midX) < 1
            expect(label, ok, "mode=\(controller.model.mode) width \(frame.width), expected \(width)")
        }
        func key(_ code: Int) {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: controller.panel.windowNumber,
                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code)
            )!
            _ = controller.handleKey(event)
        }
        let collapsedWidth = controller.model.collapsedSize.width
        let expandedWidth = NotchModel.expandedSize.width + margin * 2
        let firstRow = DeckLayout(store: store, viewState: viewState).rows.first
        let steps: [(Double, () -> Void)] = [
            (0.3, { frame("collapsed at start", width: collapsedWidth); controller.pointerMoved(to: top) }),
            (0.8, { frame("pointer on the notch expands", width: expandedWidth); controller.pointerMoved(to: insideDeck) }),
            (0.8, { frame("pointer inside the deck keeps it open", width: expandedWidth); controller.pointerMoved(to: away) }),
            (1.2, { frame("pointer away collapses", width: collapsedWidth); controller.toggleFromKeyboard() }),
            (0.8, {
                frame("shortcut expands", width: expandedWidth)
                expect("shortcut makes the deck the key window", controller.panel.isKeyWindow)
                controller.pointerMoved(to: top)
                controller.pointerMoved(to: away)
            }),
            (1.0, {
                frame("deck opened by shortcut ignores the pointer leaving", width: expandedWidth)
                key(kVK_DownArrow)
                expect("down arrow selects the first row", viewState.selectedId != nil && viewState.selectedId == firstRow?.id, viewState.selectedId ?? "nil")
                key(kVK_Tab)
                expect("tab moves to the next filter", viewState.filter == .needsYou, "\(viewState.filter)")
                viewState.filter = .all
                key(kVK_DownArrow)
                key(kVK_Return)
                expect("return opens the selected session", opened?.id == firstRow?.id, opened?.title ?? "nothing opened")
            }),
            (1.0, {
                frame("opening collapses", width: collapsedWidth)
                controller.toggleFromKeyboard()
            }),
            (0.8, { key(kVK_Escape) }),
            (1.0, {
                frame("escape collapses", width: collapsedWidth)
                print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
                exit(failures == 0 ? 0 : 1)
            }),
        ]
        var delay = 0.0
        for (wait, step) in steps {
            delay += wait
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: step)
        }
        app.run()
    }
}
