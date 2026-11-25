import Foundation
import SwiftUI

/// Optional `~/Library/Application Support/SessionDeck/config.json`:
/// {
///   "instances": { "Claude": { "label": "Work", "color": "#5AA9FF", "order": 0, "hidden": false } },
///   "notch": true,
///   "recentDays": 7,
///   "hotkey": "opt+cmd+k"
/// }
struct DeckConfig: Decodable {
    struct InstanceConfig: Decodable {
        var label: String?
        var color: String?
        var order: Int?
        var hidden: Bool?
    }

    var instances: [String: InstanceConfig] = [:]
    var notch: Bool?
    /// Sessions idle for longer are hidden until "Show older sessions" is on (pinned ones always show).
    var recentDays: Int?
    /// Opens the deck from anywhere; `"none"` turns it off.
    var hotkey: String?

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SessionDeck/config.json")
    }

    static func load() -> DeckConfig {
        guard let data = try? Data(contentsOf: fileURL) else { return DeckConfig() }
        do {
            return try JSONDecoder().decode(DeckConfig.self, from: data)
        } catch {
            deckLog("config.json ignored: \(error)")
            return DeckConfig()
        }
    }

    /// Creates an empty config the first time someone asks to edit it.
    static func ensureFileExists() {
        let url = fileURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let template = """
        {
          "instances": {
            "Claude": { "label": "Default" }
          },
          "notch": true,
          "recentDays": 7,
          "hotkey": "opt+cmd+k"
        }

        """
        try? template.write(to: url, atomically: true, encoding: .utf8)
    }
}

let instancePalette: [Color] = [
    Color(red: 0.35, green: 0.66, blue: 1.0),
    Color(red: 0.98, green: 0.55, blue: 0.35),
    Color(red: 0.4, green: 0.85, blue: 0.75),
    Color(red: 0.85, green: 0.5, blue: 0.95),
    Color(red: 0.95, green: 0.8, blue: 0.35),
    Color(red: 0.95, green: 0.45, blue: 0.6),
]

extension Color {
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// Appends to `~/Library/Logs/SessionDeck.log` (unified logging is hard to read for a personal tool).
func deckLog(_ message: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SessionDeck.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}
