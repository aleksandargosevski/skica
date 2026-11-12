import CoreGraphics
import Foundation
import Testing
@testable import SkicaCore

@Suite struct ConstraintTests {
    let fixture = Fixture()

    @Test func pinsFollowTheParent() {
        let frame = Rect(x: 10, y: 20, width: 100, height: 50)
        let old = CGSizeValue(width: 400, height: 300)
        let new = CGSizeValue(width: 600, height: 400)
        #expect(Constraints().apply(to: frame, from: old, to: new) == frame)
        #expect(Constraints(horizontal: .end, vertical: .end).apply(to: frame, from: old, to: new) == Rect(x: 210, y: 120, width: 100, height: 50))
        #expect(Constraints(horizontal: .both, vertical: .both).apply(to: frame, from: old, to: new) == Rect(x: 10, y: 20, width: 300, height: 150))
        #expect(Constraints(horizontal: .center, vertical: .center).apply(to: frame, from: old, to: new) == Rect(x: 110, y: 70, width: 100, height: 50))
        #expect(Constraints(horizontal: .scale).apply(to: frame, from: old, to: new).width == 150)
    }

    @Test func resizingAnArtboardLaysOutItsChildren() throws {
        var setup = Transaction(fixture.document)
        setup.update(fixture.upper) { $0.constraints = Constraints(horizontal: .end, vertical: .both) }
        var transaction = Transaction(setup.document)
        transaction.update(fixture.artboard) { $0.frame.width = 500; $0.frame.height = 400 }
        transaction.finalize()
        #expect(transaction[fixture.upper]?.frame == Rect(x: 150, y: 50, width: 100, height: 200))
        #expect(transaction[fixture.lower]?.frame == Rect(x: 10, y: 10, width: 100, height: 100))
    }
}

@Suite struct StackTests {
    let fixture = Fixture()

    @Test func insetsParseLikeCSS() {
        #expect(Insets(parsing: "8") == Insets(all: 8))
        #expect(Insets(parsing: "8 16") == Insets(top: 8, right: 16, bottom: 8, left: 16))
        #expect(Insets(parsing: "1 2 3 4") == Insets(top: 1, right: 2, bottom: 3, left: 4))
        #expect(Insets(parsing: "x") == nil)
        #expect(Insets(top: 8, right: 16, bottom: 8, left: 16).shorthand == "8 16")
    }

    @Test func addingAStackLinesUpTheLayers() throws {
        var transaction = Transaction(fixture.document)
        let stackResult = transaction.addStack([fixture.lower, fixture.upper])
        let stack = try #require(stackResult)
        transaction.finalize()
        let layer = try #require(transaction[stack])
        // Upper overlapped Lower, so the gap is 0; laid out side by side in a row.
        #expect(layer.stack?.direction == .horizontal)
        #expect(transaction[fixture.lower]?.frame.x == 0)
        #expect(transaction[fixture.upper]?.frame.x == 100)
        #expect(layer.frame.width == 200 && layer.frame.height == 100)
        try transaction.document.validate()
    }

    @Test func stacksApplySpacingPaddingAndAlignment() throws {
        var setup = Transaction(fixture.document)
        let stackResult = setup.addStack([fixture.lower, fixture.upper])
        let stack = try #require(stackResult)
        setup.update(fixture.upper) { $0.frame.height = 40 }
        setup.update(stack) { layer in
            layer.stack = StackLayout(direction: .horizontal, spacing: 10, padding: Insets(top: 4, right: 8, bottom: 4, left: 8), alignment: .center)
        }
        setup.finalize()
        #expect(setup[fixture.lower]?.frame == Rect(x: 8, y: 4, width: 100, height: 100))
        #expect(setup[fixture.upper]?.frame == Rect(x: 118, y: 34, width: 100, height: 40))
        #expect(setup[stack]?.frame.width == 226)
        #expect(setup[stack]?.frame.height == 108)
    }

    @Test func childrenGrowingMakeTheStackGrow() throws {
        var setup = Transaction(fixture.document)
        let label = Layer(name: "Label", kind: .text(TextContent("Go")), frame: Rect(x: 20, y: 20, width: 0, height: 0))
        setup.insert(label, into: .layer(fixture.artboard))
        setup.finalize()
        let stackResult = setup.addStack([label.id])
        let stack = try #require(stackResult)
        setup.update(stack) { $0.stack?.padding = Insets(all: 12) }
        setup.finalize()
        let before = try #require(setup[stack]?.frame.width)

        var typing = Transaction(setup.document)
        typing.update(label.id) { $0.kind = .text(TextContent("Get started now")) }
        typing.finalize()
        let after = try #require(typing[stack]?.frame.width)
        #expect(after > before + 40)
        #expect(after == (typing[label.id]?.frame.width ?? 0) + 24)
    }

    @Test func reorderingChangesTheOrderInAStack() throws {
        var setup = Transaction(fixture.document)
        let stackResult = setup.addStack([fixture.lower, fixture.upper])
        let stack = try #require(stackResult)
        setup.finalize()
        var reorder = Transaction(setup.document)
        reorder.reorder([fixture.lower], .front)
        reorder.finalize()
        #expect(reorder[fixture.upper]?.frame.x == 0)
        #expect(reorder[fixture.lower]?.frame.x == 100)
        #expect(reorder[stack]?.children == [fixture.upper, fixture.lower])
    }

    @Test func movingAStackChildSnapsBack() throws {
        var setup = Transaction(fixture.document)
        _ = setup.addStack([fixture.lower, fixture.upper])
        setup.finalize()
        var move = Transaction(setup.document)
        move.move([fixture.lower], by: CGVector(dx: 30, dy: 30))
        move.finalize()
        #expect(move[fixture.lower]?.frame.x == 0 && move[fixture.lower]?.frame.y == 0)
    }

    @Test func stacksRoundTripThroughTheFile() throws {
        var transaction = Transaction(fixture.document)
        _ = transaction.addStack([fixture.lower, fixture.upper])
        transaction.update(fixture.oval) { $0.constraints = Constraints(horizontal: .center, vertical: .scale) }
        transaction.finalize()
        let data = try DocumentArchive.encode(transaction.document)
        #expect(try DocumentArchive.decode(data) == transaction.document)
    }
}

@Suite struct LayoutCommandTests {
    let fixture = Fixture()

    @Test func stackCommandsBuildAndTuneAStack() throws {
        let editor = DocumentEditor(document: fixture.document)
        editor.select([fixture.lower, fixture.upper])
        try editor.run(commandLine: "stack v 10 4 8 center")
        let stack = try #require(editor.selectedLayers.first)
        #expect(stack.stack?.direction == .vertical)
        #expect(stack.stack?.spacing == 10)
        #expect(stack.stack?.padding == Insets(top: 4, right: 8, bottom: 4, left: 8))
        #expect(editor.document.layers[fixture.upper]?.frame.y == 114)

        try editor.run(commandLine: "gap 20; pad 0")
        #expect(editor.document.layers[fixture.upper]?.frame.y == 120)
        #expect(editor.document.layers[stack.id]?.frame.height == 220)

        try editor.run(commandLine: "stack off")
        #expect(editor.document.layers[stack.id]?.stack == nil)
        #expect(throws: InputError.self) { try editor.run(commandLine: "gap 4") }
    }

    @Test func pinSetsConstraints() throws {
        let editor = DocumentEditor(document: fixture.document)
        editor.select([fixture.upper])
        try editor.run(commandLine: "pin left right bottom")
        #expect(editor.document.layers[fixture.upper]?.constraints == Constraints(horizontal: .both, vertical: .end))
        try editor.run(commandLine: "pin vcenter")
        #expect(editor.document.layers[fixture.upper]?.constraints == Constraints(horizontal: .both, vertical: .center))
        #expect(throws: InputError.self) { try editor.run(commandLine: "pin sideways") }
    }
}
