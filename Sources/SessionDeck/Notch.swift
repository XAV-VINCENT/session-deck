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
    /// The deck is built while the pointer heads for the notch, so opening only has to animate, and dropped
    /// again a few seconds after it closes, so a hidden deck costs nothing.
    @Published var deckMounted = false

    static let wing: CGFloat = 40
    /// The deck's width, and the tallest the island may get. Its height follows the list: `expandedHeight`.
    static let expandedSize = CGSize(width: 680, height: 620)
    /// Title bar, filters and footer come to about 180pt, so under this there is no list left to shorten.
    static let minExpandedHeight: CGFloat = 220
    static let peekSize = CGSize(width: 500, height: 74)

    /// How tall the open island is right now: what the list measured, clamped. The panel keeps its full size,
    /// so a shorter deck moves the shape only, never the window.
    @Published var expandedHeight: CGFloat = NotchModel.expandedSize.height
    /// What the list last asked for, before clamping — so a capped deck can be told from a short one.
    @Published private(set) var naturalHeight: CGFloat = NotchModel.expandedSize.height

    var collapsedSize: CGSize {
        CGSize(width: notchSize.width + Self.wing * 2, height: notchSize.height)
    }

    var size: CGSize {
        switch mode {
        case .collapsed: return collapsedSize
        case .peek: return CGSize(width: max(collapsedSize.width, Self.peekSize.width), height: notchSize.height + Self.peekSize.height)
        case .expanded: return CGSize(width: Self.expandedSize.width, height: expandedHeight)
        }
    }

    /// The deck measured itself. Clamped both ways, and ignored when it barely moved, so sub-pixel
    /// relayout noise never starts an animation.
    func setExpandedHeight(_ height: CGFloat) {
        naturalHeight = height
        let clamped = min(max(height, Self.minExpandedHeight), Self.expandedSize.height)
        guard abs(clamped - expandedHeight) > 0.5 else { return }
        expandedHeight = clamped
    }

    var cornerRadius: CGFloat {
        switch mode {
        case .collapsed: return 10
        case .peek: return 22
        case .expanded: return 28
        }
    }
}

/// Springs tuned to feel instant: the deck is fully open in about 0.3 s.
enum NotchMotion {
    static let open = Animation.spring(response: 0.3, dampingFraction: 0.8)
    static let close = Animation.spring(response: 0.24, dampingFraction: 0.92)
    static let peek = Animation.spring(response: 0.34, dampingFraction: 0.74)
    /// The island growing or shrinking while it is open: a filter, or a session arriving or leaving.
    static let resize = Animation.spring(response: 0.28, dampingFraction: 0.9)
    /// Pointer on the notch this long opens the deck (filters out a cursor just passing through).
    static let hoverDelay = 0.03
    static let leaveDelay = 0.3
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
    private var lastPointer = NSPoint.zero
    private var unmountWork: DispatchWorkItem?
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
        // The panel always has the open deck's size, so SwiftUI grows the shape from the top centre in one
        // coordinate space. Where nothing is drawn (or the deck is closed) clicks go through to the app below.
        panel.ignoresMouseEvents = true

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
        mountDeck(true)
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

    /// Where a pointer heading for the notch passes first: the top of the screen around the camera.
    private var approachRect: NSRect {
        guard let screen else { return .zero }
        let width = NotchModel.expandedSize.width + 360
        return NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - 240, width: width, height: 242)
    }

    private func mountDeck(_ near: Bool) {
        if near || model.mode != .collapsed {
            unmountWork?.cancel()
            unmountWork = nil
            if !model.deckMounted { model.deckMounted = true }
        } else if model.deckMounted && unmountWork == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.model.mode == .collapsed else { return }
                self.model.deckMounted = false
                self.unmountWork = nil
            }
            unmountWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
        }
    }

    private func pointerMoved(to point: NSPoint) {
        lastPointer = point
        mountDeck(approachRect.contains(point))
        let inside = hotRect.contains(point)
        panel.ignoresMouseEvents = !(inside && model.mode != .collapsed)
        guard inside != pointerInside else { return }
        pointerInside = inside
        hoverChanged(inside)
    }

    func peek(_ session: Session) {
        guard model.mode == .collapsed else { return }
        withAnimation(NotchMotion.peek) { model.mode = .peek(session.id) }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + NotchMotion.hoverDelay, execute: work)
        } else if model.mode != .collapsed && !openedByKeyboard {
            let work = DispatchWorkItem { [weak self] in self?.collapse() }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NotchMotion.leaveDelay, execute: work)
        }
    }

    private func expand() {
        withAnimation(NotchMotion.open) { model.mode = .expanded }
        panel.ignoresMouseEvents = !hotRect.contains(lastPointer) && !openedByKeyboard
    }

    func collapse(restoreFocus: Bool = false) {
        collapseWork?.cancel()
        defer { mountDeck(approachRect.contains(lastPointer)) }
        openedByKeyboard = false
        viewState.selectedId = nil
        withAnimation(NotchMotion.close) { model.mode = .collapsed }
        panel.ignoresMouseEvents = true
        if panel.isKeyWindow {
            panel.resignKey()
            if restoreFocus { previousApp?.activate() }
        }
        previousApp = nil
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
        placePanel()
    }

    /// The largest the shape gets (the open deck) plus room for its shadow, centred under the camera.
    private static var panelSize: CGSize {
        CGSize(width: NotchModel.expandedSize.width + margin * 2, height: NotchModel.expandedSize.height + margin)
    }

    private func placePanel() {
        guard let screen else { return }
        let size = Self.panelSize
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height), display: true)
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

    /// The deck stays built while hidden, so opening draws its first frame at once; the shape reveals it from the
    /// top centre as it grows.
    private var content: some View {
        let open = model.mode == .expanded
        return ZStack(alignment: .top) {
            if model.deckMounted || open {
                DashboardView(store: store, viewState: viewState, actions: actions, notchSize: model.notchSize,
                              onNaturalHeight: { height in
                                  withAnimation(NotchMotion.resize) { model.setExpandedHeight(height) }
                              })
                    .frame(width: NotchModel.expandedSize.width, height: model.expandedHeight)
                    .opacity(open ? 1 : 0)
                    .scaleEffect(open ? 1 : 0.97, anchor: .top)
                    .animation(open ? .easeOut(duration: 0.16) : .easeIn(duration: 0.1), value: open)
                    .allowsHitTesting(open)
            }
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
                EmptyView()
            }
        }
        .frame(width: model.size.width, height: model.size.height, alignment: .top)
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
        let approaching = NSPoint(x: screen.frame.midX - 120, y: screen.frame.maxY - 160)
        var failures = 0
        func expect(_ label: String, _ ok: Bool, _ info: String = "") {
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL") \(label)\(info.isEmpty ? "" : ": \(info)")")
        }
        /// The panel never moves or resizes; the mode and whether clicks reach it change.
        func frame(_ label: String, open: Bool) {
            let frame = controller.panel.frame
            let placed = abs(frame.width - panelSize.width) < 1 && abs(frame.maxY - screen.frame.maxY) < 1 && abs(frame.midX - screen.frame.midX) < 1
            let mode = open ? controller.model.mode == .expanded : controller.model.mode == .collapsed
            let clicks = controller.panel.ignoresMouseEvents == !open
            expect(label, placed && mode && clicks, "mode=\(controller.model.mode) clicks \(controller.panel.ignoresMouseEvents ? "pass through" : "reach the deck")")
        }
        /// Captures the panel mid-animation: the black shape must stay centred under the camera while it grows.
        func checkCentred(after delays: [Double]) {
            for (index, delay) in delays.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard let view = controller.panel.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    var minX = Int.max, maxX = -1
                    for x in 0..<rep.pixelsWide {
                        guard let color = rep.colorAt(x: x, y: 2), color.alphaComponent > 0.9, color.brightnessComponent < 0.1 else { continue }
                        minX = min(minX, x)
                        maxX = max(maxX, x)
                    }
                    let scale = CGFloat(rep.pixelsWide) / view.bounds.width
                    let centre = CGFloat(minX + maxX) / 2 / CGFloat(rep.pixelsWide)
                    expect("growing deck \(index + 1) is centred", maxX > minX && abs(centre - 0.5) < 0.01,
                           String(format: "%.0f pt wide at %.0f ms, centre at %.1f%% of the panel", CGFloat(maxX - minX) / scale, delay * 1000, centre * 100))
                }
            }
        }
        func key(_ code: Int) {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: controller.panel.windowNumber,
                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code)
            )!
            _ = controller.handleKey(event)
        }
        // The live spinner and pulse are Core Animation layers: check they draw and keep animating.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        let spinner = SpinnerLayerView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        let pulse = PulseLayerView(frame: NSRect(x: 40, y: 0, width: 40, height: 40))
        spinner.configure(color: .systemBlue, lineWidth: 4)
        pulse.configure(color: .systemOrange, size: 16)
        window.contentView?.addSubview(spinner)
        window.contentView?.addSubview(pulse)
        for view in [spinner, pulse] as [NSView] {
            view.layoutSubtreeIfNeeded()
            view.layout()
        }
        func inked(_ view: NSView) -> Int {
            let context = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 160,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            view.layer?.render(in: context)
            let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
            return (0..<1600).filter { pixels[$0 * 4 + 3] > 0 }.count
        }
        expect("live spinner draws and spins", inked(spinner) > 50 && spinner.isSpinning, "\(inked(spinner)) px")
        expect("live pulse draws and pulses", inked(pulse) > 50 && pulse.isPulsing, "\(inked(pulse)) px")

        let firstRow = DeckLayout(store: store, viewState: viewState).rows.first
        var tallest: CGFloat = 0
        let steps: [(Double, () -> Void)] = [
            (0.3, {
                frame("collapsed at start", open: false)
                expect("no deck built while the pointer is away", !controller.model.deckMounted)
                controller.pointerMoved(to: approaching)
            }),
            (0.3, {
                expect("pointer heading for the notch builds the deck", controller.model.deckMounted)
                FrameProbe.start()
                controller.pointerMoved(to: top)
            }),
            (0.8, {
                frame("pointer on the notch expands", open: true)
                let report = FrameProbe.stop()
                expect("opening starts fast", report.firstFrame < 0.1, String(format: "first frame after %.0f ms", report.firstFrame * 1000))
                print(String(format: "INFO opening animation: %d frames in %.0f ms, %.0f fps (screen max %d Hz)",
                             report.frames, report.duration * 1000, report.fps, screen.maximumFramesPerSecond))
                controller.pointerMoved(to: insideDeck)
            }),
            (0.8, { frame("pointer inside the deck keeps it open", open: true); controller.pointerMoved(to: away) }),
            (1.2, { frame("pointer away collapses", open: false)
                controller.toggleFromKeyboard()
                checkCentred(after: [0.05, 0.1])
            }),
            (0.8, {
                frame("shortcut expands", open: true)
                expect("shortcut makes the deck the key window", controller.panel.isKeyWindow)
                controller.pointerMoved(to: top)
                controller.pointerMoved(to: away)
            }),
            (1.0, {
                expect("deck opened by shortcut ignores the pointer leaving", controller.model.mode == .expanded)
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
                frame("opening collapses", open: false)
                controller.toggleFromKeyboard()
            }),
            // The island is only as tall as the list. Every demo filter still overflows the cap, so the
            // short case is a search that leaves one session; the panel behind it must not move either way.
            (0.8, {
                viewState.filter = .all
                viewState.query = ""
            }),
            (0.8, {
                tallest = controller.model.naturalHeight
                viewState.query = "flaky"
            }),
            (0.8, {
                let shortest = controller.model.expandedHeight
                let panelUnmoved = abs(controller.panel.frame.height - panelSize.height) < 1
                expect("the island is as tall as the list, no taller",
                       shortest < NotchModel.expandedSize.height - 100
                           && shortest >= NotchModel.minExpandedHeight
                           && abs(shortest - controller.model.naturalHeight) < 1
                           && panelUnmoved,
                       String(format: "%.0f pt for one session, %.0f pt asked for by all 19 (capped at %.0f), panel %@",
                              shortest, tallest, NotchModel.expandedSize.height, panelUnmoved ? "unchanged" : "RESIZED"))
                viewState.query = ""
            }),
            (0.8, {
                viewState.query = "" // the focused search field catches whatever is typed on this Mac meanwhile
                key(kVK_Escape)
            }),
            (1.0, {
                frame("escape collapses", open: false)
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
