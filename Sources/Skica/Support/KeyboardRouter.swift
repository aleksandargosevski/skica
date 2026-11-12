import AppKit
import SkicaCore

/// Routes key presses to commands before AppKit sees them, so single keys work on the canvas.
@MainActor
final class KeyboardRouter {
    private var monitor: Any?
    private var resolver = KeySequenceResolver()
    private let keymap: () -> Keymap

    /// View points per arrow press while space is held; shift moves further.
    private static let panStep: CGFloat = 60
    private static let largePanStep: CGFloat = 300

    init(keymap: @escaping () -> Keymap) {
        self.keymap = keymap
    }

    func install() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window = event.window, let controller = window.windowController as? DocumentWindowController else { return event }

        if event.type == .keyUp {
            if event.keyCode == KeyCodes.space { controller.canvas.isSpaceHeld = false }
            return event
        }

        guard let chord = KeyChord(event: event) else { return event }
        let isTyping = Self.isTyping(in: window)
        if isTyping, !chord.worksWhileTyping { return event }

        // An overlay without a text field (the shortcut list) only listens for its own keys.
        if controller.hasOverlay, !isTyping {
            if case .matched(let command) = resolver.handle(chord, bindings: keymap().bindings()),
               command == .escape || command == .showShortcuts {
                controller.perform(command)
            }
            return nil
        }

        if !isTyping, controller.canvas.penSession != nil {
            switch chord {
            case KeyChord(key: "enter"), KeyChord(key: "esc"):
                controller.canvas.finishPen(closed: false)
                return nil
            case KeyChord(key: "backspace"), KeyChord(key: "delete"):
                controller.canvas.removeLastPenPoint()
                return nil
            default:
                // Anything else (a tool key, ⌘Z…) first finishes the path.
                controller.canvas.finishPen(closed: false)
            }
        }
        if !isTyping, controller.canvas.cropEdit != nil {
            if controller.canvas.handleCropKey(chord) { return nil }
            if chord.modifiers.isDisjoint(with: [.command, .control]) { controller.canvas.endCropping() }
        }
        if !isTyping, controller.canvas.pathEdit != nil {
            if controller.canvas.handlePathKey(chord) { return nil }
            if chord.modifiers.isDisjoint(with: [.command, .control]) { controller.canvas.endPathEditing() }
        }

        if !isTyping, controller.canvas.isHinting {
            switch chord.key {
            case "esc": controller.canvas.cancelHints()
            case "backspace": controller.canvas.deleteHintLetter()
            default:
                if chord.modifiers.isEmpty, chord.key.count == 1, chord.key.first?.isLetter == true {
                    controller.canvas.typeHint(chord.key)
                } else {
                    controller.canvas.cancelHints()
                    return event
                }
            }
            return nil
        }

        if !isTyping {
            if chord == KeyChord(key: "space") {
                controller.canvas.isSpaceHeld = true
                return nil
            }
            if let (dx, dy) = Self.panDirection(event) {
                if controller.canvas.isSpaceHeld {
                    let step = event.modifierFlags.contains(.shift) ? Self.largePanStep : Self.panStep
                    controller.canvas.panByKeyboard(dx: dx * step, dy: dy * step)
                    return nil
                }
                // The layer list moves through rows with arrows itself.
                if window.firstResponder is NSOutlineView { return event }
                if event.modifierFlags.intersection([.control]).isEmpty {
                    controller.handleArrow(dx: Int(-dx), dy: Int(-dy), modifiers: event.modifierFlags)
                    return nil
                }
            }
            if window.firstResponder is NSOutlineView, chord == KeyChord(key: "enter") { return event }
        }

        switch resolver.handle(chord, bindings: keymap().bindings()) {
        case .matched(let command):
            controller.state.pendingKeys = []
            if isTyping, !command.worksWhileTyping { return event }
            controller.perform(command)
            return nil
        case .pending:
            controller.state.pendingKeys = resolver.pending
            return nil
        case .unmatched:
            controller.state.pendingKeys = []
            return event
        }
    }

    /// Arrows move the view the way the content would move: → reveals what is on the right.
    private static func panDirection(_ event: NSEvent) -> (CGFloat, CGFloat)? {
        switch KeyCodes.named[event.keyCode] {
        case "left": (1, 0)
        case "right": (-1, 0)
        case "up": (0, 1)
        case "down": (0, -1)
        default: nil
        }
    }

    static func isTyping(in window: NSWindow) -> Bool {
        guard let textView = window.firstResponder as? NSTextView else { return false }
        return textView.isEditable
    }
}

extension KeyChord {
    init?(event: NSEvent) {
        var modifiers: KeyModifiers = []
        let flags = event.modifierFlags
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }

        if let named = KeyCodes.named[event.keyCode] {
            self.init(normalizingKey: named, modifiers: modifiers)
            return
        }

        // Non-Latin layouts (e.g. Cyrillic) still trigger shortcuts by key position.
        let typed = event.charactersIgnoringModifiers ?? ""
        let key: String
        if typed.count == 1, typed.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 32 }) {
            key = typed
        } else if let position = KeyCodes.usLayout[event.keyCode] {
            key = flags.contains(.shift) ? position.shifted : position.plain
        } else {
            return nil
        }
        self.init(normalizingKey: key, modifiers: modifiers)
    }
}

/// Virtual key codes of the US layout, used for layout-independent shortcuts.
enum KeyCodes {
    static let space: UInt16 = 49

    static let named: [UInt16: String] = [
        36: "enter", 76: "enter", 53: "esc", 48: "tab", 49: "space", 51: "backspace", 117: "delete",
        126: "up", 125: "down", 123: "left", 124: "right", 115: "home", 119: "end", 116: "pageup", 121: "pagedown",
    ]

    static let usLayout: [UInt16: (plain: String, shifted: String)] = {
        let table: [(UInt16, String, String)] = [
            (0, "a", "A"), (1, "s", "S"), (2, "d", "D"), (3, "f", "F"), (4, "h", "H"), (5, "g", "G"), (6, "z", "Z"),
            (7, "x", "X"), (8, "c", "C"), (9, "v", "V"), (11, "b", "B"), (12, "q", "Q"), (13, "w", "W"), (14, "e", "E"),
            (15, "r", "R"), (16, "y", "Y"), (17, "t", "T"), (18, "1", "!"), (19, "2", "@"), (20, "3", "#"), (21, "4", "$"),
            (22, "6", "^"), (23, "5", "%"), (24, "=", "+"), (25, "9", "("), (26, "7", "&"), (27, "-", "_"), (28, "8", "*"),
            (29, "0", ")"), (30, "]", "}"), (31, "o", "O"), (32, "u", "U"), (33, "[", "{"), (34, "i", "I"), (35, "p", "P"),
            (37, "l", "L"), (38, "j", "J"), (39, "'", "\""), (40, "k", "K"), (41, ";", ":"), (42, "\\", "|"), (43, ",", "<"),
            (44, "/", "?"), (45, "n", "N"), (46, "m", "M"), (47, ".", ">"), (50, "`", "~"),
        ]
        return Dictionary(uniqueKeysWithValues: table.map { ($0.0, ($0.1, $0.2)) })
    }()
}
