import Foundation
import Testing
@testable import SkicaCore

@Suite struct PageTests {
    let fixture = Fixture()

    private func makeEditor() -> (DocumentEditor, UndoManager) {
        let editor = DocumentEditor(document: fixture.document)
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undoManager = undo
        return (editor, undo)
    }

    @Test func addsPagesAfterTheCurrentOneWithFreeNames() {
        let (editor, _) = makeEditor()
        editor.addPage()
        editor.addPage()
        #expect(editor.document.pages.map(\.name) == ["Page 1", "Page 2", "Page 3"])
        #expect(editor.page.name == "Page 3")
        editor.showAdjacentPage(forward: true)
        #expect(editor.page.name == "Page 1")
    }

    @Test func deletingAPageRemovesItsLayersAndUndoBringsThemBack() throws {
        let (editor, undo) = makeEditor()
        editor.addPage()
        editor.showPage(fixture.page)
        editor.removeCurrentPage()
        #expect(editor.document.pages.map(\.name) == ["Page 2"])
        #expect(editor.document.layers.isEmpty)
        #expect(editor.page.name == "Page 2")
        try editor.document.validate()

        undo.undo()
        #expect(editor.document.pages.count == 2)
        #expect(editor.document.layers.count == fixture.document.layers.count)
        try editor.document.validate()
    }

    @Test func theLastPageCannotBeDeleted() {
        let (editor, _) = makeEditor()
        editor.removeCurrentPage()
        #expect(editor.document.pages.count == 1)
    }

    @Test func movingLayersToAnotherPageKeepsTheirPosition() throws {
        let (editor, undo) = makeEditor()
        editor.addPage()
        let second = editor.pageID
        editor.showPage(fixture.page)
        editor.select([fixture.upper])
        editor.moveSelection(toPage: second)

        #expect(editor.pageID == second)
        #expect(editor.selection == [fixture.upper])
        #expect(editor.document.pageID(of: fixture.upper) == second)
        #expect(editor.document.layers[fixture.upper]?.frame.x == 150)
        try editor.document.validate()

        undo.undo()
        #expect(editor.pageID == fixture.page)
        #expect(editor.document.layers[fixture.upper]?.parent == fixture.artboard)
    }

    @Test func renamesPages() {
        let (editor, _) = makeEditor()
        editor.renamePage(fixture.page, to: "  Home  ")
        editor.renamePage(fixture.page, to: "   ")
        #expect(editor.page.name == "Home")
    }
}
