import AppKit
import Carbon.HIToolbox

/// A shortcut from the config, such as `"opt+cmd+k"`, `"ctrl+shift+space"` or `"none"`.
struct HotKeySpec: Equatable {
    static let defaultText = "opt+cmd+k"

    let keyCode: UInt32
    let carbonModifiers: UInt32
    let label: String

    init?(_ text: String) {
        let parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.last, let code = Self.keyCodes[key] else { return nil }
        var modifiers: UInt32 = 0
        for part in parts.dropLast() {
            switch part {
            case "ctrl", "control", "⌃": modifiers |= UInt32(controlKey)
            case "opt", "option", "alt", "⌥": modifiers |= UInt32(optionKey)
            case "shift", "⇧": modifiers |= UInt32(shiftKey)
            case "cmd", "command", "⌘": modifiers |= UInt32(cmdKey)
            default: return nil
            }
        }
        guard modifiers != 0 else { return nil }
        keyCode = UInt32(code)
        carbonModifiers = modifiers
        let symbols: [(Int, String)] = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
        label = symbols.filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined()
            + (key == "space" ? "Space" : key.uppercased())
    }

    private static let keyCodes: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
        "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
        "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "space": kVK_Space, "`": kVK_ANSI_Grave, ".": kVK_ANSI_Period, ",": kVK_ANSI_Comma,
        "/": kVK_ANSI_Slash, ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, "\\": kVK_ANSI_Backslash,
    ]
}

/// A system-wide shortcut through Carbon's `RegisterEventHotKey`: no Accessibility permission needed.
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init?(_ spec: HotKeySpec, action: @escaping () -> Void) {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { hotKey.action() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        guard installed == noErr else { return nil }
        let id = EventHotKeyID(signature: OSType(0x5344_4B31), id: 1) // 'SDK1'
        let registered = RegisterEventHotKey(spec.keyCode, spec.carbonModifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registered == noErr else {
            deckLog("hotkey \(spec.label) is taken by another app (\(registered))")
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

/// Arrow keys, Return, Tab, Escape and ⌘1-4 inside the deck, wherever it is shown.
enum DeckKeys {
    /// Returns true when the key was used (the search field then never sees it).
    static func handle(_ event: NSEvent, store: Store, viewState: DeckViewState, open: (Session) -> Void, close: () -> Void) -> Bool {
        let rows = DeckLayout(store: store, viewState: viewState).rows
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch Int(event.keyCode) {
        case kVK_DownArrow:
            move(by: 1, in: rows, viewState: viewState)
        case kVK_UpArrow:
            move(by: -1, in: rows, viewState: viewState)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            let target = rows.first { $0.id == viewState.selectedId } ?? rows.first
            guard let session = target?.session else { return true }
            open(session)
        case kVK_Escape:
            if !viewState.query.isEmpty {
                viewState.query = ""
            } else {
                close()
            }
        case kVK_Tab:
            let all = DeckFilter.allCases
            let index = all.firstIndex(of: viewState.filter) ?? 0
            let step = flags.contains(.shift) ? all.count - 1 : 1
            viewState.filter = all[(index + step) % all.count]
            viewState.selectedId = nil
        default:
            guard flags == .command, let digit = event.charactersIgnoringModifiers.flatMap(Int.init),
                  (1...DeckFilter.allCases.count).contains(digit) else { return false }
            viewState.filter = DeckFilter.allCases[digit - 1]
            viewState.selectedId = nil
        }
        return true
    }

    private static func move(by step: Int, in rows: [DeckRow], viewState: DeckViewState) {
        guard !rows.isEmpty else { return }
        guard let current = rows.firstIndex(where: { $0.id == viewState.selectedId }) else {
            viewState.selectedId = (step > 0 ? rows.first : rows.last)?.id
            return
        }
        viewState.selectedId = rows[max(0, min(rows.count - 1, current + step))].id
    }
}
