import CoreGraphics
import Foundation
import Testing
@testable import SkicaCore
@testable import SkicaRender

@Suite struct SymbolTests {
    let fixture = Fixture()

    private func makeEditor() -> (DocumentEditor, UndoManager) {
        let editor = DocumentEditor(document: fixture.document)
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undoManager = undo
        return (editor, undo)
    }

    /// Lower and Upper become the symbol "Button"; returns the instance.
    private func makeSymbol(_ editor: DocumentEditor) throws -> Layer {
        editor.select([fixture.lower, fixture.upper])
        editor.createSymbol(named: "Button")
        return try #require(editor.selectedLayers.first)
    }

    private func render(_ document: Document, page: Int = 0) throws -> Bitmap {
        let bitmap = try Bitmap(width: 700, height: 500)
        CanvasRenderer().draw(page: document.pages[page], of: document, in: bitmap.context)
        return bitmap
    }

    @Test func creatingASymbolLeavesAnInstanceThatLooksTheSame() throws {
        let (editor, undo) = makeEditor()
        let before = try render(fixture.document)
        let instance = try makeSymbol(editor)
        #expect(instance.symbolInstance != nil)
        #expect(instance.frame == Rect(x: 10, y: 10, width: 140, height: 140))
        #expect(editor.document.pages.map(\.name) == ["Page 1", "Symbols"])
        let master = try #require(editor.document.master(of: instance.symbolInstance!.symbolID))
        #expect(editor.document.layers[master]?.children == [fixture.lower, fixture.upper])
        try editor.document.validate()

        let after = try render(editor.document)
        for (x, y) in [(120, 120), (200, 200), (300, 300)] {
            #expect(after.color(x: x, y: y) == before.color(x: x, y: y), "\(x),\(y)")
        }
        undo.undo()
        #expect(editor.document == fixture.document)
    }

    @Test func instancesFollowTheirMasterAndConstraints() throws {
        let (editor, _) = makeEditor()
        let instance = try makeSymbol(editor)
        let master = try #require(editor.document.master(of: instance.symbolInstance!.symbolID))
        // Lower stretches with the instance; Upper stays at the right edge.
        editor.perform("Setup") { transaction in
            transaction.update(fixture.lower) { layer in
                layer.style.fills = [Fill(Color(hex: "#FF0000")!)]
                layer.constraints = Constraints(horizontal: .both)
            }
            transaction.update(fixture.upper) { $0.constraints = Constraints(horizontal: .end) }
        }
        editor.perform("Grow") { $0.update(instance.id) { $0.frame.width = 280 } }
        let bitmap = try render(editor.document)
        // In the 280-wide instance at page x 110: Lower spans 110…350, Upper 290…390.
        #expect(bitmap.color(x: 280, y: 120) == Color(hex: "#FF0000"))
        #expect(bitmap.color(x: 380, y: 200) == .black)
        #expect(bitmap.color(x: 200, y: 200) == Color(hex: "#FF0000"))  // where Upper used to be
        #expect(editor.document.layers[master]?.frame.width == 140)

        // Detaching keeps that layout.
        editor.select([instance.id])
        editor.detachSelectedInstances()
        let group = try #require(editor.selectedLayers.first)
        let frames = group.children.compactMap { editor.document.layers[$0]?.frame }
        #expect(frames.contains(Rect(x: 0, y: 0, width: 240, height: 100)))
        #expect(frames.contains(Rect(x: 180, y: 40, width: 100, height: 100)))
    }

    @Test func overridesChangeOneInstance() throws {
        let (editor, _) = makeEditor()
        let instance = try makeSymbol(editor)
        editor.setOverride(fixture.upper) { $0.color = Color(hex: "#00FF00")! }
        editor.setOverride(fixture.lower) { $0.isVisible = false }
        let bitmap = try render(editor.document)
        #expect(bitmap.color(x: 200, y: 200) == Color(hex: "#00FF00"))
        #expect(bitmap.color(x: 120, y: 120) == .white)  // the hidden lower one shows the artboard
        editor.resetOverrides()
        #expect(editor.document.layers[instance.id]?.symbolInstance?.overrides.isEmpty == true)
    }

    @Test func detachingMakesAGroupWithOverridesApplied() throws {
        let (editor, _) = makeEditor()
        _ = try makeSymbol(editor)
        editor.setOverride(fixture.upper) { $0.color = Color(hex: "#00FF00")! }
        editor.detachSelectedInstances()
        let group = try #require(editor.selectedLayers.first)
        #expect(group.kind == .group)
        let children = group.children.compactMap { editor.document.layers[$0] }
        #expect(children.count == 2)
        #expect(children.last?.style.fills.first?.color == Color(hex: "#00FF00"))
        try editor.document.validate()
    }

    @Test func deletingAMasterDetachesItsInstances() throws {
        let (editor, _) = makeEditor()
        let instance = try makeSymbol(editor)
        let master = try #require(editor.document.master(of: instance.symbolInstance!.symbolID))
        editor.showPage(editor.document.pageID(of: master)!)
        editor.select([master])
        editor.deleteSelectionDetachingInstances()
        #expect(editor.document.layers[instance.id] == nil)
        #expect(editor.document.layers.values.contains { $0.kind == .group && $0.name == "Button" })
        try editor.document.validate()
    }

    @Test func artboardsBecomeSymbolsInPlace() throws {
        var transaction = Transaction(fixture.document)
        let created = transaction.createSymbol(from: [fixture.artboard], name: "Card")
        #expect(created?.instance == nil)
        #expect(transaction[fixture.artboard]?.symbolID != nil)
        #expect(transaction[fixture.artboard]?.isArtboard == true)
    }

    @Test func instancesPasteIntoOtherDocumentsWithTheirMaster() throws {
        let (editor, _) = makeEditor()
        let instance = try makeSymbol(editor)
        let clipboard = try LayerClipboard.decode(LayerClipboard(copying: [instance.id], from: editor.document).encoded())
        #expect(clipboard.masters.count == 1)

        let target = DocumentEditor(document: Document())
        target.paste(clipboard)
        let pasted = try #require(target.selectedLayers.first?.symbolInstance)
        #expect(target.document.master(of: pasted.symbolID) != nil)
        #expect(target.document.pages.map(\.name) == ["Page 1", "Symbols"])
        try target.document.validate()

        // Pasting again reuses the master that is now there.
        target.paste(clipboard)
        #expect(target.document.symbolMasters.count == 1)
    }

    @Test func nestedSymbolsDrawAndCyclesStop() throws {
        var transaction = Transaction(fixture.document)
        let innerResult = transaction.createSymbol(from: [fixture.lower], name: "Inner")
        let inner = try #require(innerResult)
        let innerInstance = try #require(inner.instance)
        let outerResult = transaction.createSymbol(from: [innerInstance], name: "Outer")
        let outer = try #require(outerResult)
        let outerMaster = outer.master
        // A cycle: the inner master shows the outer symbol.
        let outerID = try #require(transaction[outerMaster]?.symbolID)
        transaction.insert(Layer(name: "Loop", kind: .symbolInstance(SymbolInstance(symbolID: outerID)), frame: Rect(x: 0, y: 0, width: 10, height: 10)),
                           into: .layer(inner.master))
        let bitmap = try render(transaction.document)
        #expect(bitmap.color(x: 20, y: 120) != nil)  // drawing finished
        #expect(SVGWriter.svg(of: fixture.artboard, in: transaction.document) != nil)
    }

    @Test func overridableLayersIncludeNestedSymbols() throws {
        var transaction = Transaction(fixture.document)
        let innerResult = transaction.createSymbol(from: [fixture.lower], name: "Inner")
        let inner = try #require(innerResult)
        let outerResult = transaction.createSymbol(from: [inner.instance!, fixture.upper], name: "Outer")
        let outer = try #require(outerResult)
        let symbolID = try #require(transaction[outer.master]?.symbolID)
        let names = transaction.document.overridableLayers(of: symbolID).map(\.layer.name)
        #expect(names == ["Upper", "Inner", "Lower"])
    }
}

@Suite struct SharedStyleTests {
    let fixture = Fixture()

    @Test func sharedStylesUpdateEveryLinkedLayer() throws {
        let editor = DocumentEditor(document: fixture.document)
        editor.select([fixture.lower])
        editor.perform("Red") { $0.update(fixture.lower) { $0.style.fills = [Fill(Color(hex: "#FF0000")!)] } }
        editor.createSharedStyle(named: "Danger")
        let styleID = try #require(editor.document.layers[fixture.lower]?.sharedStyleID)

        editor.select([fixture.oval])
        editor.applySharedStyle(styleID)
        #expect(editor.document.layers[fixture.oval]?.style.fills.first?.color == Color(hex: "#FF0000"))

        // Change one layer, then push its look to the shared style: the other follows.
        editor.perform("Blue") { $0.update(fixture.oval) { $0.style.fills = [Fill(Color(hex: "#0000FF")!)] } }
        #expect(editor.document.isOutOfSync(fixture.oval))
        editor.updateSharedStyleFromSelection()
        #expect(editor.document.layers[fixture.lower]?.style.fills.first?.color == Color(hex: "#0000FF"))
        #expect(!editor.document.isOutOfSync(fixture.lower))
    }

    @Test func textStylesOnlyApplyToText() throws {
        var transaction = Transaction(fixture.document)
        let text = Layer(name: "T", kind: .text(TextContent("Hi", style: TextStyle(fontSize: 30))), frame: Rect(x: 0, y: 0, width: 0, height: 0))
        transaction.insert(text, into: .page(fixture.page))
        let styleIDResult = transaction.createSharedStyle(from: text.id, name: "Title")
        let styleID = try #require(styleIDResult)
        transaction.applySharedStyle(styleID, to: [fixture.oval])
        #expect(transaction[fixture.oval]?.sharedStyleID == nil)
    }

    @Test func deletingAStyleKeepsTheLook() throws {
        var transaction = Transaction(fixture.document)
        let styleIDResult = transaction.createSharedStyle(from: fixture.lower, name: "Box")
        let styleID = try #require(styleIDResult)
        transaction.deleteSharedStyle(styleID)
        #expect(transaction[fixture.lower]?.sharedStyleID == nil)
        #expect(transaction.document.assets.sharedStyles.isEmpty)
        #expect(transaction[fixture.lower]?.style == fixture.document.layers[fixture.lower]?.style)
    }

    @Test func assetsAreUndoable() {
        let editor = DocumentEditor(document: fixture.document)
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undoManager = undo
        editor.addSwatch(Color(hex: "#5B5BD6")!, name: "Brand")
        editor.addSwatch(Color(hex: "#5B5BD6")!, name: "Again")   // the same color is not added twice
        #expect(editor.document.assets.swatches.map(\.name) == ["Brand"])
        undo.undo()
        #expect(editor.document.assets.swatches.isEmpty)
    }

    @Test func commandLineUsesSwatchesAndStyles() throws {
        let editor = DocumentEditor(document: fixture.document)
        editor.addSwatch(Color(hex: "#5B5BD6")!, name: "Brand Primary")
        editor.select([fixture.lower])
        editor.createSharedStyle(named: "Box")
        editor.select([fixture.oval])
        try editor.run(commandLine: "fill $brandprimary")
        #expect(editor.document.layers[fixture.oval]?.style.fills.first?.color == Color(hex: "#5B5BD6"))
        try editor.run(commandLine: "style box")
        #expect(editor.document.layers[fixture.oval]?.sharedStyleID != nil)
        #expect(throws: InputError.self) { try editor.run(commandLine: "fill $nope") }
    }

    @Test func assetsRoundTripAndOldFilesStillOpen() throws {
        var transaction = Transaction(fixture.document)
        transaction.addSwatch(.black, name: "Ink")
        transaction.createSharedStyle(from: fixture.lower, name: "Box")
        let data = try DocumentArchive.encode(transaction.document)
        #expect(try DocumentArchive.decode(data) == transaction.document)

        let old = #"{"version":1,"pages":[{"id":"p","name":"Page 1","layers":[]}],"layers":{}}"#
        let document = try JSONDecoder().decode(Document.self, from: Data(old.utf8))
        #expect(document.assets == DocumentAssets())
    }
}
