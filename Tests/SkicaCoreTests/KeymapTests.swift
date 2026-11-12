import Foundation
import Testing
@testable import SkicaCore

@Suite struct KeymapTests {
    @Test func parsesChords() {
        #expect(KeyChord(parsing: "cmd+=") == KeyChord(key: "=", modifiers: .command))
        #expect(KeyChord(parsing: "cmd+shift++") == KeyChord(key: "+", modifiers: [.command, .shift]))
        #expect(KeyChord(parsing: "shift+r") == KeyChord(key: "R"))
        #expect(KeyChord(parsing: "return") == KeyChord(key: "enter"))
        #expect(KeyChord(parsing: "hyper+x") == nil)
    }

    @Test(arguments: KeymapPreset.allCases)
    func presetsHaveNoConflicts(preset: KeymapPreset) {
        let keymap = Keymap(preset: preset)
        for command in CommandID.allCases {
            #expect(keymap.conflicts(for: command).isEmpty, "\(command) conflicts in \(preset)")
        }
    }

    @Test func presetShortcutsAllParse() {
        for preset in KeymapPreset.allCases {
            for (command, texts) in preset.defaults {
                #expect(Keymap(preset: preset).sequences(for: command).count == texts.count, "\(command) in \(preset)")
            }
        }
    }

    @Test func resolvesSequences() {
        var resolver = KeySequenceResolver()
        let bindings: [KeySequence: CommandID] = [KeySequence(parsing: "g f")!: .zoomToFit]
        #expect(resolver.handle(KeyChord(key: "g"), bindings: bindings) == .pending)
        #expect(resolver.handle(KeyChord(key: "f"), bindings: bindings) == .matched(.zoomToFit))
        #expect(resolver.handle(KeyChord(key: "x"), bindings: bindings) == .unmatched)
    }

    @Test func loadsOverridesAndReportsProblems() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("skica-keys-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"preset":"figma","bindings":{"zoomIn":["z"],"nope":["x"],"zoomOut":["cmd+abc"]}}"#.utf8).write(to: url)

        let (keymap, warnings) = KeymapStore(fileURL: url).load()
        #expect(keymap.preset == .figma)
        #expect(keymap.sequences(for: .zoomIn) == [KeySequence(parsing: "z")!])
        #expect(warnings.count == 2)
    }
}
