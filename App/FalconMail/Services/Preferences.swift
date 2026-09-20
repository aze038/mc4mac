import SwiftUI
import AppKit

enum Preferences {
    static func bool(_ key: String, default d: Bool) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? d }
    static func int(_ key: String, default d: Int) -> Int { UserDefaults.standard.object(forKey: key) as? Int ?? d }
    static func string(_ key: String, default d: String) -> String { UserDefaults.standard.string(forKey: key) ?? d }
    static func set(_ value: Any, _ key: String) { UserDefaults.standard.set(value, forKey: key) }
}

enum ListDensity: String, CaseIterable, Identifiable {
    case compact, comfortable

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .compact: return "Compact"
        case .comfortable: return "Comfortable"
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    static func apply(_ raw: String) {
        switch AppAppearance(rawValue: raw) ?? .system {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

enum SystemSounds {
    static let none = "None"

    static var names: [String] {
        let dir = URL(fileURLWithPath: "/System/Library/Sounds")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let names = files.filter { $0.pathExtension == "aiff" }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
        return names.isEmpty ? ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"] : names
    }

    static func play(_ name: String) {
        guard name != none else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
