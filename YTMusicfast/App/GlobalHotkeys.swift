import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

/// System-wide shortcuts that work while another app is in front (Carbon hot keys: no
/// Accessibility permission needed). Each action is off until you record a shortcut for it.
@MainActor
@Observable
final class GlobalHotkeys {
    static let shared = GlobalHotkeys()

    enum Action: String, CaseIterable, Identifiable, Codable {
        case playPause, next, previous, like, showApp
        var id: String { rawValue }

        var title: String {
            switch self {
            case .playPause: String(localized: "Play / pause")
            case .next: String(localized: "Next song")
            case .previous: String(localized: "Previous song")
            case .like: String(localized: "Like / unlike the song")
            case .showApp: String(localized: "Show YT Musicfast")
            }
        }

        @MainActor func perform() {
            let player = PlayerController.shared
            switch self {
            case .playPause: player.togglePlayPause()
            case .next: player.next()
            case .previous: player.previous()
            case .like:
                guard let track = player.current, !track.isLocal else { return }
                player.toggleLike()
                Router.shared.showToast(player.isLiked(track) ? String(localized: "Added to Liked Music") : String(localized: "Removed from Liked Music"),
                                        icon: player.isLiked(track) ? "heart.fill" : "heart")
            case .showApp:
                NSApp.activate()
                NSApp.windows.first { $0.title == "YT Musicfast" }?.makeKeyAndOrderFront(nil)
            }
        }
    }

    struct Combo: Codable, Hashable {
        /// Virtual key code (kVK_…).
        var keyCode: UInt32
        /// NSEvent modifier flags (device independent).
        var modifiers: UInt

        var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

        var carbonModifiers: UInt32 {
            var result: UInt32 = 0
            if flags.contains(.command) { result |= UInt32(cmdKey) }
            if flags.contains(.option) { result |= UInt32(optionKey) }
            if flags.contains(.control) { result |= UInt32(controlKey) }
            if flags.contains(.shift) { result |= UInt32(shiftKey) }
            return result
        }

        /// "⌃⌥⌘P"
        var display: String {
            var text = ""
            if flags.contains(.control) { text += "⌃" }
            if flags.contains(.option) { text += "⌥" }
            if flags.contains(.shift) { text += "⇧" }
            if flags.contains(.command) { text += "⌘" }
            return text + Self.keyName(keyCode)
        }

        private static let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                                           kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]

        static func keyName(_ code: UInt32) -> String {
            switch Int(code) {
            case kVK_Space: return String(localized: "Space")
            case kVK_LeftArrow: return "←"
            case kVK_RightArrow: return "→"
            case kVK_UpArrow: return "↑"
            case kVK_DownArrow: return "↓"
            case kVK_Return: return "↩"
            case kVK_Delete: return "⌫"
            case kVK_Escape: return "⎋"
            case let code where functionKeys.contains(code):
                return "F\((functionKeys.firstIndex(of: code) ?? 0) + 1)"
            default:
                return Self.character(for: code)?.uppercased() ?? "#\(code)"
            }
        }

        /// The character a key makes on the current keyboard layout.
        private static func character(for code: UInt32) -> String? {
            guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
                  let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
            let layout = unsafeBitCast(data, to: CFData.self)
            guard let bytes = CFDataGetBytePtr(layout) else { return nil }
            var deadKeys: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { pointer in
                UCKeyTranslate(pointer, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                               OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
            }
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }

    private(set) var shortcuts: [Action: Combo] = [:]
    /// Shortcuts macOS or another app already owns.
    private(set) var conflicts: Set<Action> = []

    @ObservationIgnored private var registered: [Action: EventHotKeyRef] = [:]
    @ObservationIgnored private var handler: EventHandlerRef?
    private static let storageKey = "globalHotkeys"
    private static let signature: OSType = 0x5954_4D46  // "YTMF"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([Action: Combo].self, from: data) {
            shortcuts = saved
        }
    }

    /// Installs the event handler and registers the saved shortcuts (at launch).
    func start() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let index = Int(id.id)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if Action.allCases.indices.contains(index) { Action.allCases[index].perform() }
                }
            }
            return noErr
        }, 1, &type, nil, &handler)
        registerAll()
    }

    func set(_ combo: Combo?, for action: Action) {
        // One action per combo.
        if let combo { for (other, existing) in shortcuts where existing == combo && other != action { shortcuts[other] = nil } }
        shortcuts[action] = combo
        if let data = try? JSONEncoder().encode(shortcuts) { UserDefaults.standard.set(data, forKey: Self.storageKey) }
        registerAll()
    }

    private func registerAll() {
        for ref in registered.values { UnregisterEventHotKey(ref) }
        registered = [:]
        conflicts = []
        guard handler != nil else { return }
        for (action, combo) in shortcuts {
            guard let index = Action.allCases.firstIndex(of: action) else { continue }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, EventHotKeyID(signature: Self.signature, id: UInt32(index)),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { registered[action] = ref } else { conflicts.insert(action) }
        }
    }
}

/// "Record Shortcut" button: press the keys (with ⌘, ⌥ or ⌃), Esc cancels, Delete clears.
struct ShortcutRecorder: View {
    let action: GlobalHotkeys.Action
    @State private var recording = false
    @State private var monitor: Any?
    /// The app's own key handling (Space, ⌘K…) steps aside while this is set.
    @MainActor static var isRecording = false
    private var hotkeys: GlobalHotkeys { .shared }

    var body: some View {
        HStack(spacing: 6) {
            if hotkeys.conflicts.contains(action) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help(String(localized: "Another app already uses this shortcut"))
            }
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? String(localized: "Press keys…") : hotkeys.shortcuts[action]?.display ?? String(localized: "Record Shortcut"))
                    .monospacedDigit()
                    .frame(minWidth: 110)
            }
            .buttonStyle(.bordered)
            .tint(recording ? .accentColor : nil)
            if hotkeys.shortcuts[action] != nil, !recording {
                Button {
                    hotkeys.set(nil, for: action)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Clear shortcut"))
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        Self.isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            switch Int(event.keyCode) {
            case kVK_Escape:
                stop()
            case kVK_Delete, kVK_ForwardDelete:
                hotkeys.set(nil, for: action)
                stop()
            default:
                // A global shortcut needs ⌘, ⌥ or ⌃, or it would steal plain typing everywhere.
                guard !flags.intersection([.command, .option, .control]).isEmpty else { NSSound.beep(); return nil }
                hotkeys.set(GlobalHotkeys.Combo(keyCode: UInt32(event.keyCode), modifiers: flags.rawValue), for: action)
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        Self.isRecording = false
    }
}
