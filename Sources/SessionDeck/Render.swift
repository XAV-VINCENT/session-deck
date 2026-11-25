import AppKit
import SwiftUI

/// `SessionDeck --render <dir>`: draws the deck with the live data into PNGs (no screen access needed).
enum Render {
    static func run(into dir: URL) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let store = Store()
        store.loadNow()
        let viewState = DeckViewState(persist: false)
        let actions = DeckActions(open: { _ in }, bringToFront: { _ in })

        let dashboard = DashboardView(store: store, viewState: viewState, actions: actions)
            .frame(width: 600, height: 900)
            .background(Color(white: 0.07))
        write(dashboard, size: CGSize(width: 600, height: 900), to: dir.appendingPathComponent("dashboard-all.png"))
        viewState.filter = .needsYou
        write(dashboard, size: CGSize(width: 600, height: 900), to: dir.appendingPathComponent("dashboard-needs-you.png"))
        viewState.filter = .all

        let model = NotchModel()
        if let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            model.notchSize = CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
            print("Notch screen \(screen.localizedName): frame \(screen.frame), notch \(model.notchSize)")
        } else {
            print("No notch screen found; using \(model.notchSize)")
        }
        for (name, mode) in [("notch-collapsed", NotchModel.Mode.collapsed), ("notch-expanded", .expanded)] {
            model.mode = mode
            let size = CGSize(width: model.size.width + 60, height: model.size.height + 30)
            let root = NotchRootView(model: model, store: store, viewState: viewState, actions: actions)
                .frame(width: size.width, height: size.height)
                .background(Color(red: 0.55, green: 0.7, blue: 0.85))
            write(root, size: size, to: dir.appendingPathComponent("\(name).png"))
        }
        if let session = store.snapshot.sessions.first(where: { $0.state == .needsYou }) {
            model.mode = .peek(session.id)
            let size = CGSize(width: model.size.width + 60, height: model.size.height + 30)
            let root = NotchRootView(model: model, store: store, viewState: viewState, actions: actions)
                .frame(width: size.width, height: size.height)
                .background(Color(red: 0.55, green: 0.7, blue: 0.85))
            write(root, size: size, to: dir.appendingPathComponent("notch-peek.png"))
        }
    }

    private static func write<V: View>(_ view: V, size: CGSize, to url: URL) {
        let host = NSHostingView(rootView: view.environment(\.deckClock, Date()))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("Wrote \(url.path)")
    }
}
