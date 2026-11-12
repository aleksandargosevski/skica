import CoreGraphics
import Foundation
import Testing
@testable import SkicaCore

/// A page with one artboard at (100, 100) holding two rectangles, and a loose oval.
struct Fixture {
    var document: Document
    let page: PageID
    let artboard: LayerID
    let lower: LayerID
    let upper: LayerID
    let oval: LayerID

    init() {
        var transaction = Transaction(Document())
        let page = transaction.document.pages[0].id
        let artboard = Layer(name: "Board", kind: .artboard, frame: Rect(x: 100, y: 100, width: 400, height: 300), style: Style(fills: [Fill(.white)]))
        let lower = Layer(name: "Lower", kind: .rectangle(cornerRadius: 0), frame: Rect(x: 10, y: 10, width: 100, height: 100), style: Style(fills: [Fill(.black)]))
        let upper = Layer(name: "Upper", kind: .rectangle(cornerRadius: 0), frame: Rect(x: 50, y: 50, width: 100, height: 100), style: Style(fills: [Fill(.black)]))
        let oval = Layer(name: "Oval", kind: .oval, frame: Rect(x: 600, y: 100, width: 50, height: 50), style: Style(fills: [Fill(.black)]))
        transaction.insert(artboard, into: .page(page))
        transaction.insert(lower, into: .layer(artboard.id))
        transaction.insert(upper, into: .layer(artboard.id))
        transaction.insert(oval, into: .page(page))
        document = transaction.document
        self.page = page
        self.artboard = artboard.id
        self.lower = lower.id
        self.upper = upper.id
        self.oval = oval.id
    }
}

@Suite struct TransactionTests {
    @Test func patchAndInverseRoundTrip() throws {
        let fixture = Fixture()
        var transaction = Transaction(fixture.document)
        transaction.move([fixture.upper], by: CGVector(dx: 5, dy: -3))
        transaction.remove(fixture.lower)
        transaction.insert(Layer(name: "New", kind: .oval, frame: Rect(x: 0, y: 0, width: 1, height: 1)), into: .page(fixture.page))
        let patch = transaction.patch

        var forward = fixture.document
        forward.apply(patch)
        #expect(forward == transaction.document)
        try forward.validate()

        forward.apply(patch.inverse)
        #expect(forward == fixture.document)
    }

    @Test func emptyTransactionHasEmptyPatch() {
        var transaction = Transaction(Fixture().document)
        transaction.update(Fixture().lower) { _ in }
        #expect(transaction.patch.isEmpty)
    }

    @Test func mergedPatchesActAsOne() {
        let fixture = Fixture()
        var first = Transaction(fixture.document)
        first.move([fixture.oval], by: CGVector(dx: 1, dy: 0))
        var second = Transaction(first.document)
        second.move([fixture.oval], by: CGVector(dx: 1, dy: 0))
        let merged = first.patch.then(second.patch)
        #expect(merged.layers[fixture.oval]?.after?.frame.x == 602)
        #expect(merged.layers[fixture.oval]?.before?.frame.x == 600)

        var back = Transaction(second.document)
        back.move([fixture.oval], by: CGVector(dx: -2, dy: 0))
        #expect(merged.then(back.patch).isEmpty)
    }

    @Test func structureChangesAreDetected() {
        let fixture = Fixture()
        var move = Transaction(fixture.document)
        move.move([fixture.lower], by: CGVector(dx: 1, dy: 1))
        #expect(!move.patch.changesStructure)

        var reorder = Transaction(fixture.document)
        reorder.reorder([fixture.lower], .front)
        #expect(reorder.patch.changesStructure)
    }
}

@Suite struct EditOperationTests {
    @Test func resizeMapsBoxesAndFlipsLines() {
        let fixture = Fixture()
        var transaction = Transaction(fixture.document)
        // Upper sits at page (150, 150) with size 100.
        transaction.resize([fixture.upper], from: CGRect(x: 150, y: 150, width: 100, height: 100), to: CGRect(x: 150, y: 150, width: 200, height: 50))
        #expect(transaction[fixture.upper]?.frame == Rect(x: 50, y: 50, width: 200, height: 50))

        var line = Transaction(Document())
        let id = Tool.line.makeLayer(from: .zero, to: CGPoint(x: 100, y: 100))!
        line.insert(id, into: .page(line.document.pages[0].id))
        line.resize([id.id], from: CGRect(x: 0, y: 0, width: 100, height: 100), to: CGRect(x: 0, y: 0, width: -100, height: 100))
        #expect(line[id.id]?.frame == Rect(x: -100, y: 0, width: 100, height: 100))
        #expect(line[id.id]?.kind == .line(from: UnitPoint(x: 1, y: 0), to: UnitPoint(x: 0, y: 1)))
    }

    @Test func resizeEdgesFromEitherSide() {
        let fixture = Fixture()
        var transaction = Transaction(fixture.document)
        transaction.resizeEdges([fixture.oval], dx: 10, dy: 0, fromOpposite: false)
        #expect(transaction[fixture.oval]?.frame == Rect(x: 600, y: 100, width: 60, height: 50))
        transaction.resizeEdges([fixture.oval], dx: 10, dy: -100, fromOpposite: true)
        #expect(transaction[fixture.oval]?.frame == Rect(x: 590, y: 150, width: 70, height: 0))
    }

    @Test func reorders() {
        let fixture = Fixture()
        var transaction = Transaction(fixture.document)
        transaction.reorder([fixture.lower], .forward)
        #expect(transaction[fixture.artboard]?.children == [fixture.upper, fixture.lower])
        transaction.reorder([fixture.lower], .back)
        #expect(transaction[fixture.artboard]?.children == [fixture.lower, fixture.upper])
        transaction.reorder([fixture.artboard], .front)
        #expect(transaction.document.pages[0].layers == [fixture.oval, fixture.artboard])
    }

    @Test func reparentKeepsPagePosition() throws {
        let fixture = Fixture()
        var transaction = Transaction(fixture.document)
        transaction.reparent(fixture.upper, to: .page(fixture.page))
        #expect(transaction[fixture.upper]?.frame.x == 150)
        #expect(transaction[fixture.upper]?.parent == nil)
        try transaction.document.validate()
    }

    @Test func movedLayersJoinTheArtboardUnderThem() throws {
        let fixture = Fixture()
        var transaction = Transaction(fixture.document)
        transaction.move([fixture.oval], by: CGVector(dx: -300, dy: 50))
        transaction.adoptIntoArtboards([fixture.oval], on: fixture.page)
        #expect(transaction[fixture.oval]?.parent == fixture.artboard)
        #expect(transaction[fixture.oval]?.frame == Rect(x: 200, y: 50, width: 50, height: 50))

        transaction.move([fixture.lower], by: CGVector(dx: -1000, dy: 0))
        transaction.adoptIntoArtboards([fixture.lower], on: fixture.page)
        #expect(transaction[fixture.lower]?.parent == nil)
        try transaction.document.validate()
    }

    @Test func duplicateCopiesSubtrees() throws {
        let fixture = Fixture()
        var transaction = Transaction(fixture.document)
        let copies = transaction.duplicate([fixture.artboard, fixture.upper])
        #expect(copies.count == 1)
        let copy = try #require(transaction[copies[0]])
        #expect(copy.children.count == 2)
        #expect(copy.frame.x == 100 + 400 + 100)
        #expect(Set(copy.children).isDisjoint(with: [fixture.lower, fixture.upper]))
        try transaction.document.validate()
    }

    @Test func pasteIntoAnotherParentKeepsPagePosition() throws {
        let fixture = Fixture()
        let clipboard = LayerClipboard(copying: [fixture.upper], from: fixture.document)
        let decoded = try LayerClipboard.decode(clipboard.encoded())
        var transaction = Transaction(fixture.document)
        let pasted = transaction.paste(decoded, into: .page(fixture.page))
        #expect(transaction[pasted[0]]?.frame.x == 150)
        try transaction.document.validate()
    }
}

@Suite struct SelectionTests {
    @Test func hitTestingFindsTopmostAndRespectsClipping() throws {
        let fixture = Fixture()
        let page = try #require(fixture.document.page(fixture.page))
        let tester = HitTester(document: fixture.document, tolerance: 0)
        #expect(tester.path(at: CGPoint(x: 170, y: 170), on: page) == [fixture.artboard, fixture.upper])
        #expect(tester.path(at: CGPoint(x: 115, y: 115), on: page) == [fixture.artboard, fixture.lower])
        #expect(tester.path(at: CGPoint(x: 450, y: 350), on: page) == [fixture.artboard])
        #expect(tester.path(at: CGPoint(x: 625, y: 125), on: page) == [fixture.oval])
        #expect(tester.path(at: CGPoint(x: 601, y: 101), on: page).isEmpty)  // outside the oval's curve
    }

    @Test func hiddenAndLockedLayersLetClicksThrough() throws {
        var fixture = Fixture()
        fixture.document.layers[fixture.upper]?.isLocked = true
        let page = try #require(fixture.document.page(fixture.page))
        #expect(HitTester(document: fixture.document).path(at: CGPoint(x: 170, y: 170), on: page) == [fixture.artboard, fixture.lower])
    }

    @Test func rotatedShapesAreHitInTheirRotatedOutline() throws {
        var fixture = Fixture()
        fixture.document.layers[fixture.oval]?.kind = .rectangle(cornerRadius: 0)
        fixture.document.layers[fixture.oval]?.rotation = 45
        let page = try #require(fixture.document.page(fixture.page))
        let tester = HitTester(document: fixture.document, tolerance: 0)
        #expect(tester.path(at: CGPoint(x: 601, y: 101), on: page).isEmpty)
        #expect(tester.path(at: CGPoint(x: 625, y: 92), on: page) == [fixture.oval])
    }

    @Test func clicksSkipArtboards() {
        let fixture = Fixture()
        let target = SelectionRules.clickTarget(path: [fixture.artboard, fixture.upper], in: fixture.document, selection: [], deep: false)
        #expect(target == fixture.upper)
        #expect(SelectionRules.clickTarget(path: [fixture.artboard], in: fixture.document, selection: [], deep: false) == nil)
    }

    @Test func marqueeSelectsInsideArtboardsOrWholeArtboards() throws {
        let fixture = Fixture()
        let page = try #require(fixture.document.page(fixture.page))
        #expect(SelectionRules.marquee(CGRect(x: 0, y: 0, width: 130, height: 130), on: page, in: fixture.document) == [fixture.lower])
        #expect(Set(SelectionRules.marquee(CGRect(x: 0, y: 0, width: 1000, height: 1000), on: page, in: fixture.document)) == [fixture.artboard, fixture.oval])
    }

    @Test func siblingNavigationFollowsTheLayerList() {
        let fixture = Fixture()
        #expect(SelectionRules.sibling(of: fixture.upper, in: fixture.document, forward: true) == fixture.lower)
        #expect(SelectionRules.sibling(of: fixture.lower, in: fixture.document, forward: true) == fixture.upper)
        #expect(SelectionRules.firstChild(of: fixture.artboard, in: fixture.document) == fixture.upper)
        #expect(fixture.document.listOrder(of: fixture.document.pages[0]) == [fixture.oval, fixture.artboard, fixture.upper, fixture.lower])
    }
}

@Suite struct InputTests {
    @Test func evaluatesArithmetic() throws {
        #expect(try NumericExpression.evaluate("100/4") == 25)
        #expect(try NumericExpression.evaluate("(2+3)*4") == 20)
        #expect(try NumericExpression.evaluate("-5 + 2") == -3)
        #expect(try NumericExpression.evaluate("1,5*2") == 3)
        #expect(try NumericExpression.evaluate("+20", current: 100) == 120)
        #expect(try NumericExpression.evaluate("*2", current: 100) == 200)
        #expect(throws: InputError.self) { try NumericExpression.evaluate("1/0") }
        #expect(throws: InputError.self) { try NumericExpression.evaluate("12px") }
        #expect(throws: InputError.self) { try NumericExpression.evaluate("+2") }
    }

    @Test func parsesGeometry() throws {
        let current = Rect(x: 10, y: 20, width: 100, height: 50)
        #expect(try GeometryPrompt.parse("200x120", current: current) == GeometryInput(width: 200, height: 120))
        #expect(try GeometryPrompt.parse("200 × 120 @ 40, 80", current: current) == GeometryInput(width: 200, height: 120, x: 40, y: 80))
        #expect(try GeometryPrompt.parse("@ 40 80", current: current) == GeometryInput(x: 40, y: 80))
        #expect(try GeometryPrompt.parse("150", current: current) == GeometryInput(width: 150, height: 150))
        #expect(try GeometryPrompt.parse("x*2", current: current) == GeometryInput(height: 100))
        #expect(try GeometryPrompt.parse("+10x @ ,+5", current: current) == GeometryInput(width: 110, y: 25))
        #expect(throws: InputError.self) { try GeometryPrompt.parse("big", current: current) }
    }

    @Test func fuzzyMatchesPreferWordStarts() throws {
        let fit = try #require(FuzzyMatch.score("zf", in: "Zoom to Fit"))
        let other = try #require(FuzzyMatch.score("zf", in: "Zoom Out of Frame Selection"))
        #expect(FuzzyMatch.score("xyz", in: "Zoom to Fit") == nil)
        #expect(fit > other)
    }

    @Test func linesFollowTheDragDirection() {
        let line = Tool.line.makeLayer(from: CGPoint(x: 0, y: 100), to: CGPoint(x: 100, y: 0))
        #expect(line?.kind == .line(from: UnitPoint(x: 0, y: 1), to: UnitPoint(x: 1, y: 0)))
        #expect(line?.frame == Rect(x: 0, y: 0, width: 100, height: 100))
    }
}
