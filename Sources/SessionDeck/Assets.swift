import AppKit
import SwiftUI

/// `SessionDeck --render-assets <dir>`: the app icon and the README pictures, drawn by the real views
/// with the demo data (`DemoData`), so no real session ever lands in a picture.
enum Assets {
    static let notch = CGSize(width: 185, height: 32)

    static func run(into dir: URL) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let store = Store(demo: true)
        store.loadNow()
        let viewState = DeckViewState(persist: false)
        let actions = DeckActions(open: { _ in }, bringToFront: { _ in })

        // Icon: 1024 px master, then every size macOS asks for.
        let icon = render(DeckIcon(size: 512, iconMargin: true), size: CGSize(width: 512, height: 512))
        save(icon, to: dir.appendingPathComponent("icon.png"))
        makeIcns(from: dir.appendingPathComponent("icon.png"), into: dir)

        func notchImage(_ mode: NotchModel.Mode, selected: String? = nil) -> NSBitmapImageRep {
            let model = NotchModel()
            model.notchSize = notch
            model.mode = mode
            viewState.selectedId = selected
            let size = CGSize(width: model.size.width + 56, height: model.size.height + 28)
            return render(NotchRootView(model: model, store: store, viewState: viewState, actions: actions), size: size)
        }
        let expanded = notchImage(.expanded, selected: "local_demo_w3")
        let collapsed = notchImage(.collapsed)
        let peek = notchImage(.peek("local_demo_f1"))
        viewState.selectedId = nil

        // Hero: the deck dropped from the notch over a desktop.
        let heroSize = CGSize(width: 1440, height: 800)
        save(render(
            ZStack(alignment: .top) {
                DeckWallpaper(scale: 1.9)
                FakeMenuBar(store: store)
                image(expanded)
            }
            .frame(width: heroSize.width, height: heroSize.height),
            size: heroSize
        ), to: dir.appendingPathComponent("hero.jpg"))

        // The two quiet states, cropped to the top of the screen.
        for (name, rep, height) in [("notch-collapsed", collapsed, 96.0), ("notch-peek", peek, 168.0)] {
            let size = CGSize(width: 1000, height: height)
            save(render(
                ZStack(alignment: .top) {
                    DeckWallpaper(scale: 1.2)
                    FakeMenuBar(store: store, menus: ["File", "Edit"], compact: true)
                    image(rep)
                }
                .frame(width: size.width, height: size.height),
                size: size
            ), to: dir.appendingPathComponent("\(name).png"))
        }

        // The menu bar popover, for screens without a notch.
        let popoverDeck = render(
            DashboardView(store: store, viewState: viewState, actions: actions)
                .frame(width: 640, height: 660)
                .background(Color.black),
            size: CGSize(width: 640, height: 660)
        )
        let popoverSize = CGSize(width: 1100, height: 780)
        save(render(
            ZStack(alignment: .topTrailing) {
                DeckWallpaper(scale: 1.6)
                FakeMenuBar(store: store, highlightStatusItem: true, showNotch: false)
                PopoverFrame(deck: image(popoverDeck))
                    .padding(.top, 40)
                    .padding(.trailing, 170)
            }
            .frame(width: popoverSize.width, height: popoverSize.height),
            size: popoverSize
        ), to: dir.appendingPathComponent("menubar.jpg"))

        // Social preview, 1280 x 640 (rendered at 2x, then halved).
        let og = render(OGImage(deck: image(expanded)), size: CGSize(width: 1280, height: 640))
        save(downscale(og, to: CGSize(width: 1280, height: 640)), to: dir.appendingPathComponent("og-image.png"))
    }

    // MARK: - Pictures

    private struct FakeMenuBar: View {
        @ObservedObject var store: Store
        var menus = ["File", "Edit", "View", "Window", "Help"]
        var compact = false
        var highlightStatusItem = false
        var showNotch = true

        var body: some View {
            let running = store.current.filter { $0.state == .running }.count
            let needsYou = store.current.filter(DeckFilter.needsYou.admits).count
            ZStack(alignment: .top) {
                HStack(spacing: 20) {
                    Image(systemName: "apple.logo").font(.system(size: 14, weight: .semibold))
                    Text("Claude").font(.system(size: 13, weight: .bold))
                    ForEach(menus, id: \.self) { Text($0) }
                    Spacer()
                    HStack(spacing: 4) {
                        Image(nsImage: MenuBarIcon.image).renderingMode(.template)
                        Text("●").font(.system(size: 9)).foregroundStyle(SessionState.running.color)
                        Text(verbatim: "\(running)")
                        Text("●").font(.system(size: 9)).foregroundStyle(SessionState.needsYou.color)
                        Text(verbatim: "\(needsYou)")
                    }
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(highlightStatusItem ? 0.22 : 0)))
                    if !compact {
                        Image(systemName: "wifi")
                        Image(systemName: "battery.75percent")
                        Image(systemName: "switch.2")
                        Text("Tue 9:41")
                    }
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(height: 32)
                .background(Color.black.opacity(0.22))
                if showNotch {
                    NotchShape(radius: 10).fill(Color.black).frame(width: notch.width, height: notch.height)
                }
            }
        }
    }

    private struct PopoverFrame: View {
        let deck: Image

        var body: some View {
            VStack(alignment: .trailing, spacing: 0) {
                Triangle()
                    .fill(Color.black)
                    .frame(width: 22, height: 10)
                    .padding(.trailing, 60)
                deck
                    .frame(width: 640, height: 660)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            }
            .shadow(color: .black.opacity(0.5), radius: 30, y: 14)
        }
    }

    private struct Triangle: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
            return path
        }
    }

    private struct OGImage: View {
        let deck: Image

        var body: some View {
            ZStack(alignment: .topLeading) {
                DeckWallpaper(scale: 1.7)
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                deck
                    .resizable()
                    .frame(width: 736 * 0.86, height: 648 * 0.86)
                    .offset(x: 1280 - 736 * 0.86 + 6, y: 0)
                VStack(alignment: .leading, spacing: 0) {
                    DeckIcon(size: 104)
                        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
                    Text("Session Deck")
                        .font(.system(size: 66, weight: .heavy, design: .rounded))
                        .padding(.top, 26)
                    Text("Every Claude Code session, from every Claude profile, one notch away.")
                        .font(.system(size: 25, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineSpacing(4)
                        .frame(width: 500, alignment: .leading)
                        .padding(.top, 12)
                    HStack(spacing: 10) {
                        pill("Dynamic Island deck", color: SessionState.running.color)
                        pill("Opens the right window", color: SessionState.needsYou.color)
                    }
                    .padding(.top, 30)
                    HStack(spacing: 10) {
                        pill("⌥⌘K from anywhere", color: SessionState.review.color)
                        pill("Native Swift", color: SessionState.done.color)
                    }
                    .padding(.top, 10)
                }
                .foregroundStyle(.white)
                .padding(.leading, 70)
                .padding(.top, 62)
            }
            .frame(width: 1280, height: 640)
            .clipped()
        }

        private func pill(_ text: String, color: Color) -> some View {
            HStack(spacing: 7) {
                Circle().fill(color).frame(width: 8, height: 8).shadow(color: color, radius: 4)
                Text(text).font(.system(size: 16, weight: .semibold))
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(Capsule().fill(Color.white.opacity(0.1)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        }
    }

    // MARK: - Rendering

    private static func image(_ rep: NSBitmapImageRep) -> Image {
        let image = NSImage(size: NSSize(width: CGFloat(rep.pixelsWide) / 2, height: CGFloat(rep.pixelsHigh) / 2))
        image.addRepresentation(rep)
        return Image(nsImage: image)
    }

    /// Draws a view at 2x through AppKit, so text fields, menus and scroll views look like the app.
    static func render<V: View>(_ view: V, size: CGSize) -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private static func downscale(_ rep: NSBitmapImageRep, to size: CGSize) -> NSBitmapImageRep {
        let out = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        out.size = size
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: out)!
        context.imageInterpolation = .high
        NSGraphicsContext.current = context
        rep.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    private static func save(_ rep: NSBitmapImageRep, to url: URL) {
        let data = url.pathExtension == "jpg"
            ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
            : rep.representation(using: .png, properties: [:])
        try? data?.write(to: url)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        print("Wrote \(url.lastPathComponent) \(rep.pixelsWide)x\(rep.pixelsHigh) \(bytes / 1024) KB")
    }

    private static func makeIcns(from master: URL, into dir: URL) {
        let iconset = dir.appendingPathComponent("AppIcon.iconset")
        try? FileManager.default.removeItem(at: iconset)
        try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = points * scale
                let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
                run("/usr/bin/sips", ["-z", "\(pixels)", "\(pixels)", master.path, "--out", iconset.appendingPathComponent(name).path])
            }
        }
        run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", dir.appendingPathComponent("AppIcon.icns").path])
        try? FileManager.default.removeItem(at: iconset)
        print("Wrote AppIcon.icns")
    }

    private static func run(_ tool: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}

// MARK: - Animation

extension Assets {
    /// `SessionDeck --render-animation <dir>`: the notch opening, keyboard selection, a filter and the
    /// banner, drawn frame by frame with a fixed clock, then encoded by `img2webp` (Homebrew `webp`) as
    /// `notch-demo.webp`. Lossless: lossy frames leave block edges on the wallpaper gradient.
    static func renderAnimation(into dir: URL) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let frames = dir.appendingPathComponent("frames")
        try? FileManager.default.removeItem(at: frames)
        try? FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)

        let store = Store(demo: true)
        store.loadNow()
        let viewState = DeckViewState(persist: false)
        let frame = AnimationFrame()
        let peekSession = store.snapshot.sessions.first { $0.id == "local_demo_f1" }!
        let size = CGSize(width: 860, height: 680)
        let host = NSHostingView(rootView: AnimationCanvas(frame: frame, store: store, viewState: viewState)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host

        let fps = 20.0
        let start = Date()
        var index = 0
        func shoot(_ seconds: Double, _ update: (Double) -> Void) {
            let count = max(1, Int((seconds * fps).rounded()))
            for step in 0..<count {
                update(Double(step + 1) / fps)
                frame.clock = start.addingTimeInterval(Double(index) / fps)
                RunLoop.main.run(until: Date().addingTimeInterval(0.03))
                host.layoutSubtreeIfNeeded()
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
                )!
                rep.size = size
                host.cacheDisplay(in: host.bounds, to: rep)
                let small = downscale(rep, to: CGSize(width: size.width * 1.5, height: size.height * 1.5))
                try? small.representation(using: .png, properties: [:])?
                    .write(to: frames.appendingPathComponent(String(format: "f%04d.png", index)))
                index += 1
            }
        }
        func spring(_ t: Double, response: Double, damping: Double) -> CGFloat {
            let omega = 2 * Double.pi / response
            let damped = omega * (1 - damping * damping).squareRoot()
            return CGFloat(1 - exp(-damping * omega * t) * (cos(damped * t) + damping * omega / damped * sin(damped * t)))
        }
        let rows = { DeckLayout(store: store, viewState: viewState).rows.map(\.id) }

        shoot(0.9) { _ in frame.progress = 0 }
        frame.target = .expanded
        shoot(0.6) { t in frame.progress = spring(t, response: 0.42, damping: 0.78) }
        shoot(0.5) { _ in frame.progress = 1 }
        for id in rows().prefix(3) {
            shoot(0.4) { _ in viewState.selectedId = id }
        }
        shoot(1.2) { _ in
            viewState.selectedId = nil
            viewState.filter = .needsYou
        }
        shoot(0.45) { t in frame.progress = 1 - spring(t, response: 0.32, damping: 0.9) }
        viewState.filter = .all
        shoot(0.6) { _ in frame.progress = 0 }
        frame.target = .peek(peekSession)
        shoot(0.55) { t in frame.progress = spring(t, response: 0.42, damping: 0.72) }
        shoot(1.6) { _ in frame.progress = 1 }
        shoot(0.45) { t in frame.progress = 1 - spring(t, response: 0.32, damping: 0.9) }
        shoot(0.5) { _ in frame.progress = 0 }
        print("Rendered \(index) frames")

        let names = (0..<index).map { frames.appendingPathComponent(String(format: "f%04d.png", $0)).path }
        let out = dir.appendingPathComponent("notch-demo.webp")
        run("/opt/homebrew/bin/img2webp", ["-loop", "0", "-min_size", "-d", "\(Int(1000 / fps))", "-lossless", "-m", "4"] + names + ["-o", out.path])
        if ProcessInfo.processInfo.environment["KEEP_FRAMES"] == nil { try? FileManager.default.removeItem(at: frames) }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
        print("Wrote notch-demo.webp \(bytes / 1024) KB")
    }

    final class AnimationFrame: ObservableObject {
        enum Target {
            case expanded
            case peek(Session)
        }

        @Published var progress: CGFloat = 0
        @Published var target = Target.expanded
        @Published var clock = Date()
    }

    private struct AnimationCanvas: View {
        @ObservedObject var frame: AnimationFrame
        @ObservedObject var store: Store
        @ObservedObject var viewState: DeckViewState

        var body: some View {
            ZStack(alignment: .top) {
                DeckWallpaper(scale: 1.4)
                FakeMenuBar(store: store, menus: ["File", "Edit", "View"], compact: true)
                MorphingNotch(frame: frame, store: store, viewState: viewState)
            }
            .environment(\.deckClock, frame.clock)
        }
    }

    /// The real notch content with its size and corners driven by `progress` (0 = collapsed, 1 = open).
    private struct MorphingNotch: View {
        @ObservedObject var frame: AnimationFrame
        @ObservedObject var store: Store
        @ObservedObject var viewState: DeckViewState

        var body: some View {
            let p = frame.progress
            let clamped = min(max(p, 0), 1)
            let collapsed = CGSize(width: notch.width + NotchModel.wing * 2, height: notch.height)
            let (target, targetRadius): (CGSize, CGFloat) = {
                switch frame.target {
                case .expanded: return (NotchModel.expandedSize, 28)
                case .peek: return (CGSize(width: NotchModel.peekSize.width, height: notch.height + NotchModel.peekSize.height), 22)
                }
            }()
            let size = CGSize(
                width: collapsed.width + (target.width - collapsed.width) * p,
                height: collapsed.height + (target.height - collapsed.height) * p
            )
            let radius = 10 + (targetRadius - 10) * clamped
            return ZStack(alignment: .top) {
                NotchShape(radius: radius)
                    .fill(Color.black)
                    .shadow(color: .black.opacity(0.55 * clamped), radius: 22, y: 10)
                NotchRim(radius: radius)
                    .stroke(LinearGradient(colors: [.white.opacity(0), .white.opacity(0.14)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                    .opacity(clamped)
                ZStack(alignment: .top) {
                    switch frame.target {
                    case .expanded:
                        NotchWings(store: store, notchSize: notch)
                            .opacity(max(0, 1 - clamped * 3))
                        DashboardView(store: store, viewState: viewState, actions: DeckActions(open: { _ in }, bringToFront: { _ in }), notchSize: notch)
                            .frame(width: target.width, height: target.height)
                            .opacity(min(1, max(0, (clamped - 0.3) / 0.5)))
                            .scaleEffect(0.96 + 0.04 * clamped, anchor: .top)
                    case .peek(let session):
                        VStack(spacing: 0) {
                            NotchWings(store: store, notchSize: notch)
                            PeekCard(session: session, instance: store.snapshot.instance(session.instanceId), onOpen: { _ in })
                                .frame(width: target.width, height: NotchModel.peekSize.height)
                                .opacity(min(1, max(0, (clamped - 0.4) / 0.5)))
                        }
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(NotchShape(radius: radius))
            }
            .frame(width: size.width, height: size.height)
        }
    }
}
