import CoreGraphics
import Foundation
import Testing
@testable import SkicaCore

@Suite struct CommandLineTests {
    let fixture = Fixture()

    private func editor(selecting ids: [LayerID]) -> DocumentEditor {
        let editor = DocumentEditor(document: fixture.document)
        editor.select(ids)
        return editor
    }

    @Test func parsesCommands() throws {
        #expect(try LineCommandParser.parse("w 200; h +20") == [.width("200"), .height("+20")])
        #expect(try LineCommandParser.parse("fill none") == [.fill(nil)])
        #expect(try LineCommandParser.parse("border 2 #000 inside") == [.border(width: 2, color: .black, position: .inside)])
        #expect(try LineCommandParser.parse("font Helvetica Neue 16 700") == [.font(family: "Helvetica Neue", size: 16, weight: 700)])
        #expect(try LineCommandParser.parse("font bold") == [.font(family: nil, size: nil, weight: 700)])
        #expect(try LineCommandParser.parse("blend color burn") == [.blend(.colorBurn)])
        #expect(try LineCommandParser.parse("align c") == [.align(.horizontalCenter)])
        #expect(throws: InputError.self) { try LineCommandParser.parse("wobble 3") }
        #expect(throws: InputError.self) { try LineCommandParser.parse("fill blue-ish") }
    }

    @Test func setsValuesPerLayerWithArithmetic() throws {
        let editor = editor(selecting: [fixture.lower, fixture.oval])
        try editor.run(commandLine: "w *2; x +5; fill #FF0000; r 8")
        #expect(editor.document.layers[fixture.lower]?.frame == Rect(x: 15, y: 10, width: 200, height: 100))
        #expect(editor.document.layers[fixture.oval]?.frame.width == 100)
        #expect(editor.document.layers[fixture.oval]?.style.fills.first?.color == Color(hex: "#FF0000"))
        #expect(editor.document.layers[fixture.lower]?.kind == .rectangle(cornerRadius: 8))
        #expect(editor.document.layers[fixture.oval]?.kind == .oval)
    }

    @Test func mistakesChangeNothing() {
        let editor = editor(selecting: [fixture.lower])
        #expect(throws: InputError.self) { try editor.run(commandLine: "w 1/0") }
        #expect(editor.document == fixture.document)
    }

    @Test func actionsAreReturnedForTheWindow() throws {
        let editor = editor(selecting: [fixture.lower])
        #expect(try editor.run(commandLine: "group; hide") == [.group])
        #expect(editor.document.layers[fixture.lower]?.isVisible == false)
    }

    @Test func sizesTakePresetNames() throws {
        let editor = editor(selecting: [fixture.artboard])
        try editor.run(commandLine: "size iphone se")
        #expect(editor.document.layers[fixture.artboard]?.frame.width == 375)
        #expect(ArtboardPreset.matching("ipm")?.name == "iPhone 16 Pro Max")
        #expect(ArtboardPreset.matching("a4")?.name == "A4")
    }

    @Test func changesFontsByFamilyAndWeight() throws {
        var transaction = Transaction(fixture.document)
        let text = Layer(name: "T", kind: .text(TextContent("Hi")), frame: Rect(x: 0, y: 0, width: 0, height: 0))
        transaction.insert(text, into: .page(fixture.page))
        let editor = DocumentEditor(document: transaction.document)
        editor.select([text.id])
        try editor.run(commandLine: "font Helvetica Neue 30 700")
        let style = try #require(editor.document.layers[text.id]?.textContent?.leadingStyle)
        #expect(style.fontName == "HelveticaNeue-Bold")
        #expect(style.fontSize == 30)
        #expect(throws: InputError.self) { try editor.run(commandLine: "font NoSuchFamily") }
    }

    @Test func alignsAndDistributes() {
        let editor = editor(selecting: [fixture.lower, fixture.upper])
        editor.perform("Align") { $0.align([fixture.lower, fixture.upper], .right) }
        #expect(editor.document.worldBounds(of: fixture.lower)?.maxX == 250)

        let single = self.editor(selecting: [fixture.upper])
        single.perform("Align") { $0.align([fixture.upper], .left) }   // to the artboard
        #expect(single.document.layers[fixture.upper]?.frame.x == 0)

        var transaction = Transaction(fixture.document)
        let third = Layer(name: "Third", kind: .oval, frame: Rect(x: 300, y: 10, width: 20, height: 20))
        transaction.insert(third, into: .layer(fixture.artboard))
        transaction.update(fixture.upper) { $0.frame.x = 200 }
        transaction.distribute([fixture.lower, fixture.upper, third.id], horizontally: true)
        // lower 10…110, third ends at 320: 310 of space minus 220 of widths leaves two gaps of 45.
        #expect(transaction[fixture.upper]?.frame.x == 155)
    }

    @Test func hintLabelsArePrefixFree() {
        #expect(HintLabels.labels(count: 3) == ["a", "s", "d"])
        let many = HintLabels.labels(count: 30)
        #expect(many.count == 30 && many.allSatisfy { $0.count == 2 })
        #expect(Set(many).count == 30)
    }

    @Test func hintTargetsFollowReadingOrder() throws {
        let page = try #require(fixture.document.page(fixture.page))
        let targets = HintLabels.targets(on: page, in: fixture.document, selection: [], area: CGRect(x: 0, y: 0, width: 2000, height: 2000))
        #expect(targets.first == fixture.artboard || targets.first == fixture.oval)
        #expect(Set(targets) == [fixture.artboard, fixture.lower, fixture.upper, fixture.oval])
    }
}
