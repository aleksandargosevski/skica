import CoreGraphics
import Foundation
import Testing
@testable import SkicaCore

@Suite struct DocumentEditorTests {
    let fixture = Fixture()
    let editor: DocumentEditor
    let undo = UndoManager()

    init() {
        undo.groupsByEvent = false
        editor = DocumentEditor(document: fixture.document)
        editor.undoManager = undo
    }

    private var ovalX: Double? { editor.document.layers[fixture.oval]?.frame.x }

    @Test func undoAndRedoRestoreDocumentAndSelection() {
        editor.select([fixture.oval])
        editor.duplicateSelection()
        let copy = editor.selection
        #expect(editor.document.layers.count == fixture.document.layers.count + 1)

        undo.undo()
        #expect(editor.document == fixture.document)
        #expect(editor.selection == [fixture.oval])

        undo.redo()
        #expect(editor.selection == copy)
        #expect(editor.document.layers.count == fixture.document.layers.count + 1)
    }

    @Test func quickNudgesMergeIntoOneStep() {
        editor.select([fixture.oval])
        for _ in 0..<3 { editor.nudge(dx: 10, dy: 0) }
        #expect(ovalX == 630)
        undo.undo()
        #expect(ovalX == 600)
        #expect(!undo.canUndo)
    }

    @Test func otherEditsEndTheMerge() {
        editor.select([fixture.oval])
        editor.nudge(dx: 10, dy: 0)
        editor.toggleLocked()
        editor.nudge(dx: 10, dy: 0)
        undo.undo()
        #expect(ovalX == 610)
    }

    @Test func liveEditsBecomeOneStepAndCanBeCancelled() {
        editor.select([fixture.oval])
        editor.beginLiveEdit()
        for step in 1...5 {
            editor.updateLiveEdit { $0.move([fixture.oval], by: CGVector(dx: Double(step), dy: 0)) }
        }
        #expect(ovalX == 605)
        editor.endLiveEdit("Move")
        undo.undo()
        #expect(ovalX == 600)

        editor.beginLiveEdit()
        editor.updateLiveEdit { $0.move([fixture.oval], by: CGVector(dx: 50, dy: 0)) }
        editor.cancelLiveEdit()
        #expect(editor.document == fixture.document)
    }

    @Test func notifiesWhatChanged() {
        var changes: [String] = []
        editor.observe { change in
            switch change {
            case .document(let patch): changes.append("document:\(patch.layers.count)")
            case .selection: changes.append("selection")
            case .tool: changes.append("tool")
            case .page: changes.append("page")
            }
        }
        editor.select([fixture.oval])
        editor.nudge(dx: 1, dy: 0)
        editor.tool = .rectangle
        #expect(changes == ["selection", "document:1", "tool"])
    }

    @Test func insertsShapesIntoTheArtboardUnderTheCenter() throws {
        let id = try #require(editor.insertShape(.oval, centeredAt: CGPoint(x: 300, y: 250)))
        let layer = try #require(editor.document.layers[id])
        #expect(layer.parent == fixture.artboard)
        #expect(layer.frame == Rect(x: 150, y: 100, width: 100, height: 100))
        #expect(editor.selection == [id])
    }

    @Test func pastesIntoTheSelectedArtboard() {
        let clipboard = LayerClipboard(copying: [fixture.oval], from: editor.document)
        editor.select([fixture.artboard])
        editor.paste(clipboard)
        let pasted = editor.selection
        #expect(pasted.count == 1)
        #expect(editor.document.layers[pasted[0]]?.parent == fixture.artboard)
        #expect(editor.document.layers[pasted[0]]?.frame.x == 500)
    }

    @Test func selectionIgnoresMissingLayers() {
        editor.select([fixture.oval, LayerID("missing"), fixture.oval])
        #expect(editor.selection == [fixture.oval])
    }
}
