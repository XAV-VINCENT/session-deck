import AppKit
import SwiftUI

enum DeckFilter: String, CaseIterable, Identifiable {
    case needsYou, running, watching, all
    var id: String { rawValue }

    var label: String {
        switch self {
        case .needsYou: return "Needs you"
        case .running: return "Running"
        case .watching: return "Watching"
        case .all: return "All"
        }
    }

    var tint: Color {
        switch self {
        case .needsYou: return SessionState.needsYou.color
        case .running: return SessionState.running.color
        case .watching: return SessionState.review.color
        case .all: return .white
        }
    }

    func admits(_ session: Session) -> Bool {
        switch self {
        case .needsYou: return session.state == .needsYou || session.state == .error
        case .running: return session.state == .running
        case .watching: return session.state == .review
        case .all: return true
        }
    }
}

/// Shared by the notch and the menu bar popover, so both show the same filter, search and selection.
final class DeckViewState: ObservableObject {
    @Published var filter: DeckFilter = .all
    @Published var query = ""
    /// The row the arrow keys moved to (the pointer only highlights).
    @Published var selectedId: String?
    /// Bumped to move the keyboard focus into the search field.
    @Published var focusToken = 0
    @Published var collapsed: Set<String> {
        didSet { if persist { UserDefaults.standard.set(Array(collapsed), forKey: "collapsedProfiles") } }
    }
    private let persist: Bool

    /// `persist: false` for the demo, the pictures and the self-test, so they never touch the real preferences.
    init(persist: Bool = true) {
        self.persist = persist
        collapsed = persist ? Set(UserDefaults.standard.stringArray(forKey: "collapsedProfiles") ?? []) : []
    }

    func toggleCollapsed(_ instanceId: String) {
        if collapsed.contains(instanceId) { collapsed.remove(instanceId) } else { collapsed.insert(instanceId) }
    }
}

/// The deck's own height, summed from its parts: the title bar, the filters, the hairlines, the list at its
/// natural height and the footer. The notch island follows it so the shape is as tall as the sessions in it.
struct DeckHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}

extension View {
    /// Adds this view's laid-out height to the deck's. Measuring beats arithmetic here: a row is one or two
    /// lines depending on its detail text, and the title bar is as tall as this Mac's notch.
    func addingToDeckHeight() -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: DeckHeightKey.self, value: proxy.size.height)
        })
    }
}

struct DeckActions {
    var open: (Session) -> Void
    var bringToFront: (Instance) -> Void
}

// MARK: - Layout

struct DeckRow: Identifiable {
    let session: Session
    let depth: Int
    let parentTitle: String?
    let isLastChild: Bool
    var id: String { session.id }
}

struct DeckBucket: Identifiable {
    let title: String
    let order: Int
    var rows: [DeckRow]
    var id: String { title }
}

struct DeckSection: Identifiable {
    let instance: Instance
    let buckets: [DeckBucket]
    let recentCount: Int
    /// Terminal sessions whose `claude` process is still running.
    let openCount: Int
    let olderHidden: Int
    let counts: [SessionState: Int]
    let isCollapsed: Bool
    var id: String { instance.id }
    var isEmpty: Bool { buckets.isEmpty }
}

/// What the deck shows, in order: one section per profile, then the user's sidebar groups.
/// The keyboard walks `rows`, so it always matches what is on screen.
struct DeckLayout {
    let sections: [DeckSection]

    var rows: [DeckRow] { sections.filter { !$0.isCollapsed }.flatMap { $0.buckets.flatMap(\.rows) } }
    var isEmpty: Bool { sections.allSatisfy(\.isEmpty) }

    init(store: Store, viewState: DeckViewState) {
        let query = viewState.query.trimmingCharacters(in: .whitespaces).lowercased()
        let current = store.current
        let titles = Dictionary(current.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        sections = store.snapshot.instances.compactMap { instance in
            let mine = current.filter { $0.instanceId == instance.id }
            let visible = mine.filter { viewState.filter.admits($0) && (query.isEmpty || $0.searchText.contains(query)) }
            guard !visible.isEmpty || (viewState.filter == .all && query.isEmpty) else { return nil }
            var counts: [SessionState: Int] = [:]
            for session in mine { counts[session.state, default: 0] += 1 }
            return DeckSection(
                instance: instance,
                buckets: Self.buckets(visible, titles: titles),
                recentCount: mine.count,
                openCount: mine.filter { $0.cli?.isOpen == true }.count,
                olderHidden: store.showOlder ? 0 : store.olderCount(of: instance.id),
                counts: counts,
                isCollapsed: query.isEmpty && viewState.collapsed.contains(instance.id)
            )
        }
    }

    /// Mirrors the sidebar: Pinned, the user's groups in their order, then the rest, newest first.
    /// Side sessions sit under their parent when the parent is shown too.
    private static func buckets(_ sessions: [Session], titles: [String: String]) -> [DeckBucket] {
        let visibleIds = Set(sessions.map(\.id))
        var children: [String: [Session]] = [:]
        var roots: [Session] = []
        for session in sessions.sorted(by: { $0.lastActivity > $1.lastActivity }) {
            if let parent = session.parentId, visibleIds.contains(parent), parent != session.id {
                children[parent, default: []].append(session)
            } else {
                roots.append(session)
            }
        }
        var buckets: [String: DeckBucket] = [:]
        for root in roots {
            let (title, order): (String, Int) = root.isStarred ? ("Pinned", -1)
                : root.group.map { ($0.name, $0.order) } ?? ("Sessions", 10_000)
            var rows = [DeckRow(session: root, depth: 0, parentTitle: root.parentId.flatMap { titles[$0] }, isLastChild: true)]
            appendChildren(of: root.id, depth: 1, children: children, into: &rows)
            buckets[title, default: DeckBucket(title: title, order: order, rows: [])].rows += rows
        }
        return buckets.values.sorted { $0.order == $1.order ? $0.title < $1.title : $0.order < $1.order }
    }

    private static func appendChildren(of id: String, depth: Int, children: [String: [Session]], into rows: inout [DeckRow]) {
        guard depth < 4, let kids = children[id] else { return }
        for (index, child) in kids.enumerated() {
            rows.append(DeckRow(session: child, depth: depth, parentTitle: nil, isLastChild: index == kids.count - 1))
            appendChildren(of: child.id, depth: depth + 1, children: children, into: &rows)
        }
    }
}

// MARK: - Deck

struct DashboardView: View {
    @ObservedObject var store: Store
    @ObservedObject var viewState: DeckViewState
    let actions: DeckActions
    /// In the notch the title bar shares the menu bar row, on both sides of the camera.
    var notchSize: CGSize?
    /// Called with the height the deck wants, as the list changes. The notch island follows it; the popover
    /// and the renderers leave it nil and set a frame of their own.
    var onNaturalHeight: ((CGFloat) -> Void)?
    @FocusState private var searchFocused: Bool

    var body: some View {
        let layout = DeckLayout(store: store, viewState: viewState)
        VStack(spacing: 0) {
            titleBar.addingToDeckHeight()
            tiles.addingToDeckHeight()
            Rectangle().fill(Theme.hairline).frame(height: 1).addingToDeckHeight()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(layout.sections) { section in
                            SectionCard(
                                section: section,
                                selectedId: viewState.selectedId,
                                actions: actions,
                                toggle: { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { viewState.toggleCollapsed(section.id) } },
                                showOlder: { store.showOlder = true }
                            )
                        }
                        if layout.isEmpty {
                            emptyState
                        }
                    }
                    .padding(10)
                    .addingToDeckHeight()
                }
                .onChange(of: viewState.selectedId) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                }
            }
            Rectangle().fill(Theme.hairline).frame(height: 1).addingToDeckHeight()
            footer.addingToDeckHeight()
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .onChange(of: viewState.focusToken) { _, _ in searchFocused = true }
        .onPreferenceChange(DeckHeightKey.self) { height in
            onNaturalHeight?(height)
        }
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            DeckIcon(size: 19)
            Text("Session Deck")
                .font(Theme.rounded(13.5, .bold))
            if let notchSize {
                Spacer(minLength: notchSize.width + 24)
            } else {
                Spacer()
            }
            SearchField(text: $viewState.query, focused: $searchFocused)
                .frame(width: 170)
            SettingsMenu(store: store)
        }
        .padding(.horizontal, 14)
        .frame(height: max(notchSize?.height ?? 46, 30))
    }

    private var tiles: some View {
        HStack(spacing: 8) {
            ForEach(Array(DeckFilter.allCases.enumerated()), id: \.element) { index, filter in
                StatTile(
                    filter: filter,
                    shortcut: index + 1,
                    count: store.current.filter(filter.admits).count,
                    selected: viewState.filter == filter
                ) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { viewState.filter = filter }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, notchSize == nil ? 0 : 10)
        .padding(.bottom, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: viewState.query.isEmpty ? "checkmark.seal.fill" : "magnifyingglass")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(viewState.query.isEmpty ? SessionState.done.color : Theme.text3)
            Text(viewState.query.isEmpty ? "All clear" : "No session matches “\(viewState.query)”")
                .font(Theme.rounded(14, .bold))
            if viewState.query.isEmpty {
                Text("Nothing \(viewState.filter.label.lowercased()) right now.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text3)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            hint(["↑", "↓"], "Select")
            hint(["↩"], "Open")
            hint(["⇥"], "Filter")
            hint(["esc"], "Close")
            Spacer()
            if let label = store.hotkey?.label {
                hint([label], "Anywhere")
            }
            HStack(spacing: 5) {
                Circle().fill(SessionState.done.color).frame(width: 6, height: 6)
                    .shadow(color: SessionState.done.color, radius: 3)
                Text(verbatim: liveLabel)
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(Theme.text3)
        .padding(.horizontal, 14)
        .frame(height: 32)
    }

    private var liveLabel: String {
        let profiles = store.snapshot.instances.filter { !$0.isTerminal }.count
        let terminal = store.snapshot.instances.contains { $0.isTerminal } ? " + terminal" : ""
        return "Live · \(profiles) profile\(profiles == 1 ? "" : "s")\(terminal)"
    }

    private func hint(_ keys: [String], _ label: String) -> some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { Keycap(text: $0) }
            Text(label).padding(.leading, 2)
        }
    }
}

// MARK: - Header pieces

private struct StatTile: View {
    let filter: DeckFilter
    let shortcut: Int
    let count: Int
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    icon.frame(width: 12, height: 12)
                    Text(filter.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(selected ? Color.white : Theme.text2)
                    Spacer(minLength: 0)
                    Text(verbatim: "⌘\(shortcut)")
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.text4)
                        .opacity(hovering || selected ? 1 : 0)
                }
                Text(verbatim: "\(count)")
                    .font(Theme.rounded(24, .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(count == 0 && !selected ? Theme.text4 : .white)
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: count)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(selected ? filter.tint.opacity(filter == .all ? 0.3 : 0.6) : Color.white.opacity(0.07), lineWidth: 1)
            )
            .shadow(color: selected && filter != .all ? filter.tint.opacity(0.25) : .clear, radius: 10, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var icon: some View {
        switch filter {
        case .needsYou:
            if count > 0 { PulsingDot(color: filter.tint, size: 6) } else { Circle().fill(filter.tint.opacity(0.4)).frame(width: 6, height: 6) }
        case .running:
            if count > 0 { GradientSpinner(color: filter.tint, lineWidth: 1.8) } else { Circle().stroke(filter.tint.opacity(0.4), lineWidth: 1.5) }
        case .watching:
            Image(systemName: "eye.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(filter.tint)
        case .all:
            Image(systemName: "square.grid.2x2.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.text2)
        }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(
                selected
                    ? AnyShapeStyle(LinearGradient(
                        colors: [filter.tint.opacity(filter == .all ? 0.16 : 0.34), filter.tint.opacity(filter == .all ? 0.06 : 0.1)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    : AnyShapeStyle(Color.white.opacity(hovering ? 0.075 : 0.045))
            )
    }
}

private struct SearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.text3)
            TextField("Search sessions", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .focused(focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.text3)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(Capsule().fill(Color.white.opacity(focused.wrappedValue ? 0.12 : 0.08)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(focused.wrappedValue ? 0.2 : 0.06), lineWidth: 1))
    }
}

private struct SettingsMenu: View {
    @ObservedObject var store: Store
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        Menu {
            Toggle("Show sessions idle over \(store.recentDays) days", isOn: $store.showOlder)
            Toggle("Notify when a session finishes or needs you", isOn: $store.notifies)
            Toggle("Open at login", isOn: Binding(
                get: { launchAtLogin },
                set: { launchAtLogin = LoginItem.set($0) }
            ))
            if let label = store.hotkey?.label {
                Text("Open from anywhere: \(label)")
            }
            Divider()
            Button("Edit config…") {
                DeckConfig.ensureFileExists()
                NSWorkspace.shared.open(DeckConfig.fileURL)
            }
            Button("Reload config") { store.reloadConfig() }
            Divider()
            Button("Quit Session Deck") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.text2)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(0.08)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - Profile card

private struct SectionCard: View {
    let section: DeckSection
    let selectedId: String?
    let actions: DeckActions
    let toggle: () -> Void
    let showOlder: () -> Void

    private var instance: Instance { section.instance }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            header
            if !section.isCollapsed {
                if section.isEmpty {
                    Text(section.olderHidden > 0 ? "No recent sessions" : "No open sessions")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text3)
                        .padding(.leading, 42)
                        .padding(.vertical, 6)
                }
                ForEach(section.buckets) { bucket in
                    BucketHeader(title: bucket.title, count: bucket.rows.count)
                    ForEach(bucket.rows) { row in
                        SessionRow(
                            session: row.session,
                            depth: row.depth,
                            parentTitle: row.parentTitle,
                            isLastChild: row.isLastChild,
                            selected: row.id == selectedId,
                            onOpen: actions.open
                        )
                        .id(row.id)
                    }
                }
                if section.olderHidden > 0 {
                    Button(action: showOlder) {
                        HStack(spacing: 4) {
                            Image(systemName: "clock.arrow.circlepath").font(.system(size: 9.5))
                            Text(verbatim: "\(section.olderHidden) older session\(section.olderHidden == 1 ? "" : "s") hidden")
                            Text("Show").foregroundStyle(Theme.text2)
                        }
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.text3)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [instance.color.opacity(0.11), Color.white.opacity(0.025)], startPoint: .top, endPoint: .bottom))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(LinearGradient(colors: [instance.color.opacity(0.5), instance.color.opacity(0.08)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            ProfileAvatar(instance: instance, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(instance.label)
                    .font(Theme.rounded(13.5, .bold))
                Text(verbatim: subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text3)
            }
            Spacer(minLength: 8)
            ForEach([SessionState.needsYou, .running, .review], id: \.self) { state in
                if let count = section.counts[state], count > 0 {
                    HStack(spacing: 4) {
                        Circle().fill(state.color).frame(width: 6, height: 6)
                        Text(verbatim: "\(count)").monospacedDigit()
                    }
                    .font(Theme.rounded(11, .bold))
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(Capsule().fill(state.color.opacity(0.16)))
                    .foregroundStyle(state.color)
                    .help("\(count) \(state.label.lowercased())")
                }
            }
            if !instance.isTerminal || instance.isRunning {
                IconButton(
                    symbol: instance.isRunning ? "macwindow" : "play.fill",
                    help: instance.isTerminal ? "Show the terminal" : instance.isRunning ? "Show this Claude window" : "Start this Claude profile"
                ) {
                    actions.bringToFront(instance)
                }
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.text3)
                .rotationEffect(.degrees(section.isCollapsed ? -90 : 0))
                .frame(width: 16)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }

    private var subtitle: String {
        let sessions = "\(section.recentCount) recent session\(section.recentCount == 1 ? "" : "s")"
        if instance.isTerminal { return "Claude Code CLI · \(section.openCount) open · \(sessions)" }
        return instance.isRunning ? sessions : "Not running · \(sessions)"
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(hovering ? Color.white : Theme.text2)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.14 : 0.06)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct BucketHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            if title == "Pinned" {
                Image(systemName: "pin.fill").font(.system(size: 8.5, weight: .bold))
            }
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.9)
            Text(verbatim: "\(count)")
                .font(Theme.rounded(9.5, .semibold))
                .foregroundStyle(Theme.text4)
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
        .foregroundStyle(Theme.text3)
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.top, 10)
        .padding(.bottom, 3)
    }
}

// MARK: - Row

struct SessionRow: View {
    let session: Session
    var depth = 0
    var parentTitle: String?
    var isLastChild = true
    var selected = false
    let onOpen: (Session) -> Void
    @State private var hovering = false

    private static let indent: CGFloat = 20

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusBadge(state: session.state, size: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    trailing
                }
                if let detail = session.detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(detailColor)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                meta
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .padding(.leading, CGFloat(depth) * Self.indent)
        .background(alignment: .topLeading) {
            if depth > 0 {
                TreeConnector(depth: depth, isLast: isLastChild, indent: Self.indent)
                    .stroke(Color.white.opacity(0.16), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Theme.rowSelected : hovering ? Theme.rowHover : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.white.opacity(0.18) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onOpen(session) }
        .help(session.cli == nil ? "Open in Claude" : session.cli?.isOpen == true ? "Show its terminal" : "Resume in a terminal")
        .contextMenu { contextMenu }
    }

    @ViewBuilder private var trailing: some View {
        if hovering || selected {
            HStack(spacing: 3) {
                Text(session.cli?.isOpen == false ? "Resume" : "Open")
                Image(systemName: session.cli?.isOpen == false ? "arrow.counterclockwise" : "arrow.up.right")
                    .font(.system(size: 8.5, weight: .bold))
            }
            .font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Capsule().fill(Color.white.opacity(0.14)))
            .transition(.opacity)
        } else {
            Text(session.lastActivity.compactAgo)
                .font(Theme.rounded(10.5, .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.text3)
        }
    }

    private var detailColor: Color {
        switch session.state {
        case .needsYou: return SessionState.needsYou.color
        case .error: return SessionState.error.color.opacity(0.9)
        default: return Theme.text2
        }
    }

    private var meta: some View {
        HStack(spacing: 8) {
            MetaItem(symbol: "folder.fill", text: session.project)
            ForEach(session.pullRequests.prefix(3), id: \.self) { pr in
                PRChip(pr: pr)
            }
            if session.pullRequests.count > 3 {
                Text(verbatim: "+\(session.pullRequests.count - 3)")
                    .font(Theme.rounded(10, .semibold))
            }
            if let parentTitle {
                MetaItem(symbol: "arrow.turn.down.right", text: parentTitle)
            } else if let branch = session.branch {
                MetaItem(symbol: "arrow.triangle.branch", text: branch)
                    .truncationMode(.middle)
                    .layoutPriority(-1)
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(Theme.text3)
        .lineLimit(1)
    }

    @ViewBuilder private var contextMenu: some View {
        Button(session.cli == nil ? "Open in Claude" : session.cli?.isOpen == true ? "Show its terminal" : "Resume in a terminal") { onOpen(session) }
        ForEach(session.pullRequests.prefix(8), id: \.self) { pr in
            if let url = pr.url {
                Button("Open PR \(pr.repo.split(separator: "/").last ?? "")#\(pr.number) (\(pr.state.lowercased()))" as String) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        Divider()
        Button("Show folder in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.cwd)])
        }
        Button(session.cli == nil ? "Copy link" : "Copy resume command") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(session.cli.map { "cd '\($0.cwd)' && \($0.resumeCommand)" } ?? session.deepLink.absoluteString, forType: .string)
        }
    }
}

/// The elbow from a parent's status badge down to a side session's badge.
private struct TreeConnector: Shape {
    let depth: Int
    let isLast: Bool
    let indent: CGFloat

    func path(in rect: CGRect) -> Path {
        let x = 8 + CGFloat(depth - 1) * indent + 8
        let badgeY: CGFloat = 16
        let endX = 8 + CGFloat(depth) * indent - 3
        var path = Path()
        path.move(to: CGPoint(x: x, y: -3))
        path.addLine(to: CGPoint(x: x, y: badgeY - 6))
        path.addQuadCurve(to: CGPoint(x: x + 6, y: badgeY), control: CGPoint(x: x, y: badgeY))
        path.addLine(to: CGPoint(x: endX, y: badgeY))
        if !isLast {
            path.move(to: CGPoint(x: x, y: badgeY - 6))
            path.addLine(to: CGPoint(x: x, y: rect.maxY + 3))
        }
        return path
    }
}

private struct MetaItem: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8.5))
            Text(text)
        }
    }
}

private struct PRChip: View {
    let pr: PullRequest
    @State private var hovering = false

    var body: some View {
        Button {
            if let url = pr.url { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: pr.state == "MERGED" ? "arrow.triangle.merge" : "arrow.triangle.pull")
                    .font(.system(size: 8, weight: .bold))
                Text(verbatim: "#\(pr.number)")
                    .font(Theme.rounded(10.5, .semibold))
                    .monospacedDigit()
            }
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background(Capsule().fill(pr.color.opacity(hovering ? 0.3 : 0.16)))
            .foregroundStyle(pr.color)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(pr.repo)#\(pr.number) · \(pr.state.lowercased())")
    }
}

/// The banner under the notch when a session stops running or starts waiting for you.
struct PeekCard: View {
    let session: Session
    let instance: Instance?
    let onOpen: (Session) -> Void

    var body: some View {
        HStack(spacing: 12) {
            StatusBadge(state: session.state, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.state.headline.uppercased())
                    .font(.system(size: 9.5, weight: .heavy))
                    .tracking(0.9)
                    .foregroundStyle(session.state == .idle ? SessionState.done.color : session.state.color)
                Text(session.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let detail = session.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text2)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let instance {
                ProfileAvatar(instance: instance, size: 20)
            }
            Button { onOpen(session) } label: {
                Text("Open")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .background(Capsule().fill(Color.white))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { onOpen(session) }
    }
}

extension Session {
    var searchText: String {
        ([title, project, detail ?? "", branch ?? ""] + pullRequests.map { "#\($0.number) \($0.repo)" })
            .joined(separator: " ")
            .lowercased()
    }
}

extension Date {
    var compactAgo: String {
        let seconds = max(0, -timeIntervalSinceNow)
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86_400))d"
        }
    }
}
