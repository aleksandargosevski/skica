import Foundation

public enum KeymapPreset: String, Codable, CaseIterable, Sendable {
    case sketch
    case figma

    public var title: String {
        switch self {
        case .sketch: "Sketch"
        case .figma: "Figma"
        }
    }

    public var defaults: [CommandID: [String]] {
        var map = Self.sketchDefaults
        switch self {
        case .sketch:
            break
        case .figma:
            map[.toolArtboard] = ["f", "a"]
            map[.hintSelect] = ["g f"]
            map[.hintAdd] = ["g F"]
            map[.zoomIn] = ["+", "cmd+=", "cmd+shift++"]
            map[.zoomOut] = ["-", "cmd+-"]
            map[.zoomActualSize] = ["cmd+0", ")"]
            map[.zoomToFit] = ["cmd+1", "!"]
            map[.zoomToSelection] = ["cmd+2", "@"]
            map[.toggleHidden] = ["cmd+shift+h"]
            map[.toggleZen] = ["cmd+\\", "cmd+."]
        }
        return map
    }

    static let sketchDefaults: [CommandID: [String]] = [
        .toolSelect: ["v"],
        .toolRectangle: ["r"],
        .toolOval: ["o"],
        .toolLine: ["l"],
        .toolPolygon: ["y"],
        .toolStar: ["*"],
        .toolPen: ["p"],
        .toolText: ["t"],
        .insertImage: ["i"],
        .toolArtboard: ["a"],
        .editGeometry: ["="],
        .delete: ["backspace", "delete"],
        .duplicate: ["cmd+d"],
        .selectAll: ["cmd+a"],
        .rename: ["cmd+r"],
        .toggleHidden: ["cmd+shift+h"],
        .toggleLocked: ["cmd+shift+l"],
        .bringForward: ["cmd+]"],
        .sendBackward: ["cmd+["],
        .bringToFront: ["cmd+opt+]"],
        .sendToBack: ["cmd+opt+["],
        .group: ["cmd+g"],
        .ungroup: ["cmd+shift+g"],
        .addStack: ["A"],
        .alignLeft: ["opt+a"],
        .alignHorizontalCenter: ["opt+h"],
        .alignRight: ["opt+d"],
        .alignTop: ["opt+w"],
        .alignVerticalCenter: ["opt+v"],
        .alignBottom: ["opt+s"],
        .distributeHorizontally: ["ctrl+opt+h"],
        .distributeVertically: ["ctrl+opt+v"],
        .removeStack: ["opt+shift+a"],
        .selectNext: ["tab"],
        .selectPrevious: ["shift+tab"],
        .enterSelection: ["enter"],
        .escape: ["esc"],
        .toggleBold: ["cmd+b"],
        .toggleItalic: ["cmd+i"],
        .toggleUnderline: ["cmd+u"],
        .chooseFont: ["cmd+t"],
        .exportSelection: ["cmd+shift+e"],
        .exportMarked: ["cmd+opt+shift+e"],
        .copyAsPNG: ["cmd+shift+c"],
        .copyAsSVG: ["cmd+opt+shift+c"],
        .editPoints: ["e"],
        .convertToPaths: ["cmd+shift+o"],
        .outlineStroke: ["cmd+opt+o"],
        .booleanUnion: ["cmd+opt+u"],
        .booleanSubtract: ["cmd+opt+s"],
        .booleanIntersect: ["cmd+opt+i"],
        .booleanDifference: ["cmd+opt+x"],
        .toggleMask: ["ctrl+cmd+m"],
        .createSymbol: ["cmd+opt+k"],
        .insertSymbol: ["s"],
        .goToMaster: ["g s"],
        .detachSymbol: ["cmd+opt+b"],
        .applySharedStyle: ["cmd+shift+y"],
        .applyColor: ["c"],
        .newPage: ["cmd+opt+n"],
        .nextPage: ["pagedown"],
        .previousPage: ["pageup"],
        .goToPage: ["g p"],
        .moveToPage: ["g m"],
        .zoomIn: ["cmd+=", "cmd+shift++"],
        .zoomOut: ["cmd+-"],
        .zoomActualSize: ["cmd+0"],
        .zoomToFit: ["cmd+1"],
        .zoomToSelection: ["cmd+2"],
        .toggleLayers: ["cmd+opt+1"],
        .toggleInspector: ["cmd+opt+2"],
        .toggleZen: ["cmd+."],
        .focusLayers: ["g l"],
        .focusInspector: ["g i"],
        .commandPalette: ["cmd+p", "cmd+shift+p"],
        .selectionActions: ["cmd+k"],
        .showShortcuts: ["?"],
        .commandLine: [":"],
        .repeatCommand: ["."],
        .hintSelect: ["f"],
        .hintAdd: ["F"],
    ]
}

public struct Keymap: Equatable, Sendable {
    public var preset: KeymapPreset
    public var overrides: [CommandID: [KeySequence]]

    public init(preset: KeymapPreset = .sketch, overrides: [CommandID: [KeySequence]] = [:]) {
        self.preset = preset
        self.overrides = overrides
    }

    public func sequences(for command: CommandID) -> [KeySequence] {
        if let custom = overrides[command] { return custom }
        return (preset.defaults[command] ?? []).compactMap(KeySequence.init(parsing:))
    }

    public func primary(for command: CommandID) -> KeySequence? {
        sequences(for: command).first
    }

    public func bindings() -> [KeySequence: CommandID] {
        var result: [KeySequence: CommandID] = [:]
        for command in CommandID.allCases {
            for sequence in sequences(for: command) where result[sequence] == nil {
                result[sequence] = command
            }
        }
        return result
    }

    /// Commands that share a sequence with `command`.
    public func conflicts(for command: CommandID) -> [CommandID] {
        let mine = Set(sequences(for: command))
        return CommandID.allCases.filter { other in
            other != command && !mine.isDisjoint(with: sequences(for: other))
        }
    }
}

/// Reads `~/.config/skica/keybindings.json`:
/// `{ "preset": "sketch", "bindings": { "zoomIn": ["cmd+="] } }`. Only overrides are stored.
public struct KeymapStore: Sendable {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/skica/keybindings.json")
    }

    public let fileURL: URL

    public init(fileURL: URL = KeymapStore.defaultURL) {
        self.fileURL = fileURL
    }

    struct File: Codable {
        var preset: KeymapPreset?
        var bindings: [String: [String]]?
    }

    /// Returns the keymap and human-readable problems with entries that were skipped.
    public func load() -> (keymap: Keymap, warnings: [String]) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return (Keymap(), []) }
        let file: File
        do {
            file = try JSONDecoder().decode(File.self, from: Data(contentsOf: fileURL))
        } catch {
            return (Keymap(), ["\(fileURL.path) could not be read (\(error.localizedDescription)); using the default shortcuts."])
        }

        var warnings: [String] = []
        var overrides: [CommandID: [KeySequence]] = [:]
        for (name, sequences) in file.bindings ?? [:] {
            guard let command = CommandID(rawValue: name) else {
                warnings.append("Unknown command \"\(name)\"")
                continue
            }
            var parsed: [KeySequence] = []
            for text in sequences {
                if let sequence = KeySequence(parsing: text) {
                    parsed.append(sequence)
                } else {
                    warnings.append("Invalid shortcut \"\(text)\" for \(name)")
                }
            }
            overrides[command] = parsed
        }
        return (Keymap(preset: file.preset ?? .sketch, overrides: overrides), warnings)
    }
}

/// Matches incoming chords against bindings, waiting for the next key of sequences such as `g p`.
public struct KeySequenceResolver: Sendable {
    public enum Outcome: Equatable, Sendable {
        case matched(CommandID)
        case pending
        case unmatched
    }

    public private(set) var pending: [KeyChord] = []
    private var lastKeyTime = Date.distantPast
    public var timeout: TimeInterval = 1.5

    public init() {}

    public mutating func handle(_ chord: KeyChord, bindings: [KeySequence: CommandID], now: Date = Date()) -> Outcome {
        if now.timeIntervalSince(lastKeyTime) > timeout { pending = [] }
        lastKeyTime = now

        let candidate = pending + [chord]
        if let command = bindings[KeySequence(candidate)] {
            pending = []
            return .matched(command)
        }
        let isPrefix = bindings.keys.contains { sequence in
            sequence.chords.count > candidate.count && Array(sequence.chords.prefix(candidate.count)) == candidate
        }
        if isPrefix {
            pending = candidate
            return .pending
        }
        if !pending.isEmpty {
            pending = []
            return handle(chord, bindings: bindings, now: now)
        }
        return .unmatched
    }

    public mutating func reset() {
        pending = []
    }
}
