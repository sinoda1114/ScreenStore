import Foundation
import SwiftUI
import AppKit

/// 1 つのショートカット (modifier + key) を表す軽量 struct。
/// UserDefaults には JSON で保存する。
struct KeyboardShortcutSpec: Codable, Equatable, Hashable, Sendable {
    /// SwiftUI の `KeyEquivalent` に渡す元キャラクタ (シフトを含まないベース)。
    /// 英数字なら小文字、記号ならそのまま (例: "2", "a", "/")。
    var keyCharacter: String
    /// `NSEvent.ModifierFlags.rawValue` のサブセット (cmd/shift/option/control のみ)。
    var modifierFlags: UInt

    init(keyCharacter: String, modifierFlags: UInt) {
        self.keyCharacter = keyCharacter
        self.modifierFlags = modifierFlags
    }

    init(keyCharacter: String, modifiers: NSEvent.ModifierFlags) {
        self.keyCharacter = keyCharacter
        self.modifierFlags = modifiers.intersection(Self.relevantMask).rawValue
    }

    static let relevantMask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    var nsModifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlags).intersection(Self.relevantMask)
    }

    var swiftUIEventModifiers: EventModifiers {
        var mods: EventModifiers = []
        let m = nsModifierFlags
        if m.contains(.command) { mods.insert(.command) }
        if m.contains(.shift)   { mods.insert(.shift) }
        if m.contains(.option)  { mods.insert(.option) }
        if m.contains(.control) { mods.insert(.control) }
        return mods
    }

    var keyEquivalent: KeyEquivalent {
        guard let ch = keyCharacter.first else { return KeyEquivalent(" ") }
        return KeyEquivalent(ch)
    }

    /// "⌃⌥⇧⌘X" 形式の人間向け文字列。
    var displayString: String {
        var s = ""
        let m = nsModifierFlags
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option)  { s += "⌥" }
        if m.contains(.shift)   { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        s += keyCharacter.uppercased()
        return s
    }

    /// 有効なショートカットかどうか (modifier が 1 つ以上 & key が 1 文字以上)。
    var isValid: Bool {
        !keyCharacter.isEmpty && !nsModifierFlags.isEmpty
    }
}

/// アプリ全体で共有するキャプチャ系ショートカット設定。
/// UserDefaults に永続化し、@Published で変更を通知する。
@MainActor
final class ShortcutSettings: ObservableObject {
    enum Key: String, CaseIterable, Sendable {
        case fullScreen = "shortcut.fullScreen"
        case window     = "shortcut.window"
        case region     = "shortcut.region"

        var defaultSpec: KeyboardShortcutSpec {
            switch self {
            case .fullScreen:
                return KeyboardShortcutSpec(keyCharacter: "2",
                                            modifiers: [.command, .shift])
            case .window:
                return KeyboardShortcutSpec(keyCharacter: "3",
                                            modifiers: [.command, .shift])
            case .region:
                return KeyboardShortcutSpec(keyCharacter: "4",
                                            modifiers: [.command, .shift])
            }
        }
    }

    private let defaults: UserDefaults

    @Published var fullScreen: KeyboardShortcutSpec
    @Published var window: KeyboardShortcutSpec
    @Published var region: KeyboardShortcutSpec

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.fullScreen = Self.read(.fullScreen, from: defaults)
        self.window     = Self.read(.window, from: defaults)
        self.region     = Self.read(.region, from: defaults)
    }

    func spec(for key: Key) -> KeyboardShortcutSpec {
        switch key {
        case .fullScreen: return fullScreen
        case .window:     return window
        case .region:     return region
        }
    }

    func update(_ key: Key, spec: KeyboardShortcutSpec) {
        switch key {
        case .fullScreen: fullScreen = spec
        case .window:     window = spec
        case .region:     region = spec
        }
        Self.write(spec, for: key, into: defaults)
    }

    func reset(_ key: Key) {
        update(key, spec: key.defaultSpec)
    }

    // MARK: - Pure serialization helpers (テスト用に内部公開)

    static func read(_ key: Key, from defaults: UserDefaults) -> KeyboardShortcutSpec {
        guard let data = defaults.data(forKey: key.rawValue),
              let decoded = try? JSONDecoder().decode(KeyboardShortcutSpec.self, from: data),
              decoded.isValid
        else {
            return key.defaultSpec
        }
        return decoded
    }

    static func write(_ spec: KeyboardShortcutSpec, for key: Key, into defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(spec) {
            defaults.set(data, forKey: key.rawValue)
        }
    }
}
