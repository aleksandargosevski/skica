import CoreGraphics
import Foundation
import Testing
@testable import SkicaCore

@Suite struct GroupTests {
    let fixture = Fixture()

    /// Lower (10,10 100×100) and Upper (50,50 100×100) grouped inside the artboard.
    private func grouped() throws -> (Transaction, LayerID) {
        var transaction = Transaction(fixture.document)
        let group = transaction.group([fixture.lower, fixture.upper])
        return (transaction, try #require(group))
    }

    @Test func groupWrapsItsMembers() throws {
        let (transaction, group) = try grouped()
        let layer = try #require(transaction[group])
        #expect(layer.frame == Rect(x: 10, y: 10, width: 140, height: 140))
        #expect(layer.children == [fixture.lower, fixture.upper])
        #expect(transaction[fixture.upper]?.frame == Rect(x: 40, y: 40, width: 100, height: 100))
        #expect(transaction[fixture.artboard]?.children == [group])
        try transaction.document.validate()
        // On the page nothing moved.
        #expect(transaction.document.worldBounds(of: fixture.upper) == fixture.document.worldBounds(of: fixture.upper))
    }

    @Test func groupsFitTheirChildrenAfterEdits() throws {
        var (transaction, group) = try grouped()
        transaction.move([fixture.upper], by: CGVector(dx: 50, dy: 0))
        transaction.fitGroups()
        #expect(transaction[group]?.frame == Rect(x: 10, y: 10, width: 190, height: 140))

        transaction.move([fixture.lower], by: CGVector(dx: -10, dy: -10))
        transaction.fitGroups()
        #expect(transaction[group]?.frame == Rect(x: 0, y: 0, width: 200, height: 150))
        #expect(transaction.document.worldBounds(of: fixture.lower)?.origin == CGPoint(x: 100, y: 100))
    }

    @Test func emptyGroupsDisappear() throws {
        var (transaction, group) = try grouped()
        transaction.remove(fixture.lower)
        transaction.remove(fixture.upper)
        transaction.fitGroups()
        #expect(transaction[group] == nil)
        try transaction.document.validate()
    }

    @Test func ungroupKeepsPositions() throws {
        var (transaction, group) = try grouped()
        transaction.update(group) { $0.opacity = 0.5 }
        let children = transaction.ungroup(group)
        #expect(children == [fixture.lower, fixture.upper])
        #expect(transaction[fixture.upper]?.frame == Rect(x: 50, y: 50, width: 100, height: 100))
        #expect(transaction[fixture.upper]?.opacity == 0.5)
        #expect(transaction[group] == nil)
        try transaction.document.validate()
    }

    @Test func resizingAGroupScalesItsChildren() throws {
        let (grouping, group) = try grouped()
        // Grouping and resizing are separate edits, as in the app.
        var transaction = Transaction(grouping.document)
        let box = try #require(transaction.document.worldBounds(of: group))
        transaction.resize([group], from: box, to: CGRect(x: box.minX, y: box.minY, width: box.width * 2, height: box.height))
        transaction.finalize()
        #expect(transaction[group]?.frame.width == 280)
        #expect(transaction[fixture.upper]?.frame == Rect(x: 80, y: 40, width: 200, height: 100))
    }

    @Test func clicksSelectTheGroupAndDoubleClicksGoInside() throws {
        let (transaction, group) = try grouped()
        let page = try #require(transaction.document.page(fixture.page))
        let path = HitTester(document: transaction.document).path(at: CGPoint(x: 170, y: 170), on: page)
        #expect(path == [fixture.artboard, group, fixture.upper])
        #expect(SelectionRules.clickTarget(path: path, in: transaction.document, selection: [], deep: false) == group)
        #expect(SelectionRules.doubleClickTarget(path: path, in: transaction.document, selection: [group]) == fixture.upper)
        // Once inside, clicks stay at the children's level.
        #expect(SelectionRules.clickTarget(path: path, in: transaction.document, selection: [fixture.lower], deep: false) == fixture.upper)
    }

    @Test func editorGroupsAndUngroupsWithUndo() {
        let editor = DocumentEditor(document: fixture.document)
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undoManager = undo
        editor.select([fixture.lower, fixture.upper])
        editor.groupSelection()
        #expect(editor.selection.count == 1)
        #expect(editor.document.layers[editor.selection[0]]?.kind == .group)

        editor.ungroupSelection()
        #expect(Set(editor.selection) == [fixture.lower, fixture.upper])
        undo.undo()
        undo.undo()
        #expect(editor.document == fixture.document)
    }
}
