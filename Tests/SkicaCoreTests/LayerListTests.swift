import CoreGraphics
import Foundation
import Testing
@testable import SkicaCore

@Suite struct LayerListMoveTests {
    let fixture = Fixture()

    @Test func reordersWithinAParent() throws {
        var transaction = Transaction(fixture.document)
        transaction.move([fixture.upper], into: .layer(fixture.artboard), at: 0)
        #expect(transaction[fixture.artboard]?.children == [fixture.upper, fixture.lower])
        // Dropping past the end puts it back on top; frames do not change.
        transaction.move([fixture.upper], into: .layer(fixture.artboard), at: 99)
        #expect(transaction[fixture.artboard]?.children == [fixture.lower, fixture.upper])
        #expect(transaction[fixture.upper]?.frame == fixture.document.layers[fixture.upper]?.frame)
        try transaction.document.validate()
    }

    @Test func movesIntoAndOutOfContainersInPlace() throws {
        let before = try #require(fixture.document.worldBounds(of: fixture.oval))
        var transaction = Transaction(fixture.document)
        transaction.move([fixture.oval], into: .layer(fixture.artboard), at: 1)
        #expect(transaction[fixture.artboard]?.children == [fixture.lower, fixture.oval, fixture.upper])
        #expect(transaction.document.worldBounds(of: fixture.oval) == before)

        transaction.move([fixture.lower], into: .page(fixture.page), at: 0)
        #expect(transaction.document.pages[0].layers.first == fixture.lower)
        #expect(transaction.document.worldBounds(of: fixture.lower) == CGRect(x: 110, y: 110, width: 100, height: 100))
        try transaction.document.validate()
    }

    @Test func severalLayersKeepTheirOrder() throws {
        var transaction = Transaction(fixture.document)
        transaction.move([fixture.upper, fixture.lower], into: .page(fixture.page), at: 2)
        #expect(transaction.document.pages[0].layers == [fixture.artboard, fixture.oval, fixture.lower, fixture.upper])
        try transaction.document.validate()
    }

    @Test func refusesImpossibleMoves() {
        let document = fixture.document
        #expect(!document.canMove([fixture.artboard], into: .layer(fixture.artboard)))
        #expect(!document.canMove([fixture.oval], into: .layer(fixture.lower)))  // not a container
        var transaction = Transaction(document)
        let group = transaction.group([fixture.lower, fixture.upper], name: "G")!
        #expect(!transaction.document.canMove([fixture.artboard], into: .layer(group)))
        #expect(transaction.move([fixture.artboard], into: .layer(group), at: 0).isEmpty)
    }

    @Test func editorMovesAreOneUndoStep() {
        let editor = DocumentEditor(document: fixture.document)
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undoManager = undo
        editor.moveLayers([fixture.oval], into: .layer(fixture.artboard), at: 0)
        #expect(editor.selection == [fixture.oval])
        undo.undo()
        #expect(editor.document == fixture.document)
    }
}

@Suite struct SpacingTests {
    let fixture = Fixture()

    @Test func exactSpacingLinesLayersUpFromTheFirst() throws {
        var transaction = Transaction(fixture.document)
        transaction.distribute([fixture.lower, fixture.oval], horizontally: true, spacing: 16)
        // Lower spans 110…210 on the page; the oval follows 16 points later.
        #expect(transaction.document.worldBounds(of: fixture.oval)?.minX == 226)
        #expect(transaction.document.uniformSpacing(of: [fixture.lower, fixture.oval], horizontally: true) == 16)
        #expect(fixture.document.uniformSpacing(of: [fixture.lower, fixture.upper, fixture.oval], horizontally: true) == nil)
    }

    @Test func commandLineTakesAGap() throws {
        let editor = DocumentEditor(document: fixture.document)
        editor.select([fixture.lower, fixture.upper])
        try editor.run(commandLine: "distribute v 8")
        #expect(editor.document.uniformSpacing(of: [fixture.lower, fixture.upper], horizontally: false) == 8)
        #expect(throws: InputError.self) { try editor.run(commandLine: "distribute h") }  // even spacing needs three
        #expect(throws: InputError.self) { try editor.run(commandLine: "distribute x 4") }
    }
}
