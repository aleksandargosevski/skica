import CoreGraphics
import Foundation
import Testing
@testable import SkicaCore
@testable import SkicaRender

@Suite struct VectorTests {
    let fixture = Fixture()

    /// A triangle path inserted with its points in parent coordinates (the frame fits itself).
    private func triangle(in transaction: inout Transaction) -> LayerID {
        let vector = VectorPath(subpaths: [Subpath(points: [
            PathPoint(CGPoint(x: 20, y: 30)), PathPoint(CGPoint(x: 60, y: 30)), PathPoint(CGPoint(x: 40, y: 70)),
        ], isClosed: true)])
        let layer = Layer(name: "Triangle", kind: .path(vector), frame: Rect(x: 0, y: 0, width: 0, height: 0), style: Style(fills: [Fill(.black)]))
        transaction.insert(layer, into: .page(fixture.page))
        transaction.finalize()
        return layer.id
    }

    @Test func framesWrapThePoints() throws {
        var transaction = Transaction(fixture.document)
        let id = triangle(in: &transaction)
        let layer = try #require(transaction[id])
        #expect(layer.frame == Rect(x: 20, y: 30, width: 40, height: 40))
        #expect(layer.vectorPath?.subpaths[0].points[0].point == CGPoint(x: 0, y: 0))
    }

    @Test func resizingScalesAndFlipsThePoints() throws {
        var transaction = Transaction(fixture.document)
        let id = triangle(in: &transaction)
        var resize = Transaction(transaction.document)
        resize.resize([id], from: CGRect(x: 20, y: 30, width: 40, height: 40), to: CGRect(x: 20, y: 30, width: 80, height: -40))
        resize.finalize()
        let layer = try #require(resize[id])
        #expect(layer.frame == Rect(x: 20, y: -10, width: 80, height: 40))
        // The tip that pointed down now points up, at the top middle.
        #expect(layer.vectorPath?.subpaths[0].points[2].point == CGPoint(x: 40, y: 0))
    }

    @Test func inspectorSizeChangesScalePoints() throws {
        var transaction = Transaction(fixture.document)
        let id = triangle(in: &transaction)
        var edit = Transaction(transaction.document)
        edit.update(id) { $0.frame.width = 20 }
        edit.finalize()
        #expect(edit[id]?.vectorPath?.subpaths[0].points[1].point == CGPoint(x: 20, y: 0))
    }

    @Test func movingAPointRefitsWithoutJumpingWhenRotated() throws {
        var transaction = Transaction(fixture.document)
        let id = triangle(in: &transaction)
        transaction.update(id) { $0.rotation = 30 }
        let before = try #require(transaction.document.worldPath(of: id)).boundingBoxOfPath
        var edit = Transaction(transaction.document)
        // Moving the first point left grows the frame; the other points must stay put on the page.
        edit.update(id) { layer in
            guard var vector = layer.vectorPath else { return }
            vector.subpaths[0].points[0].point.x -= 10
            layer.kind = .path(vector)
        }
        edit.finalize()
        let after = try #require(edit.document.worldPath(of: id))
        let tip = before.maxY
        #expect(abs(after.boundingBoxOfPath.maxY - tip) < 0.5)
        #expect(edit[id]?.frame.width == 50)
    }

    @Test func handlesFollowTheirMode() {
        var point = PathPoint(CGPoint(x: 0, y: 0), curveIn: CGPoint(x: -10, y: 0), curveOut: CGPoint(x: 10, y: 0))
        #expect(point.mode == .mirrored)
        point.setHandle(out: true, to: CGPoint(x: 0, y: 20))
        #expect(point.curveIn == CGPoint(x: 0, y: -20))

        point.mode = .asymmetric
        point.setHandle(out: true, to: CGPoint(x: 5, y: 0))
        #expect(point.curveIn == CGPoint(x: -20, y: 0))

        point.setMode(.straight, previous: nil, next: nil)
        #expect(point.curveIn == nil && point.curveOut == nil)
        point.setMode(.mirrored, previous: CGPoint(x: -30, y: 0), next: CGPoint(x: 30, y: 0))
        #expect(point.curveOut == CGPoint(x: 10, y: 0))
    }

    @Test func coreGraphicsPathsRoundTrip() {
        let ellipse = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 100, height: 50), transform: nil)
        let vector = VectorPath(ellipse)
        #expect(vector.subpaths.count == 1)
        #expect(vector.subpaths[0].isClosed)
        #expect(vector.subpaths[0].points.count == 4)  // the closing duplicate is merged
        #expect(vector.subpaths[0].points.allSatisfy { $0.mode == .asymmetric || $0.mode == .mirrored })
        #expect(vector.cgPath().boundingBoxOfPath.integral == CGRect(x: 0, y: 0, width: 100, height: 50))
    }

    @Test func shapesConvertToPathsThatLookTheSame() throws {
        var transaction = Transaction(fixture.document)
        transaction.update(fixture.upper) { $0.kind = .rectangle(cornerRadius: 10) }
        let worldBefore = try #require(transaction.document.worldBounds(of: fixture.upper))
        transaction.convertToPaths([fixture.upper, fixture.oval])
        transaction.finalize()
        #expect(transaction[fixture.upper]?.vectorPath != nil)
        #expect(transaction[fixture.oval]?.vectorPath?.subpaths.first?.isClosed == true)
        #expect(transaction.document.worldBounds(of: fixture.upper) == worldBefore)
    }

    @Test func textBecomesLetterOutlines() throws {
        var transaction = Transaction(fixture.document)
        let text = Layer(name: "Hi", kind: .text(TextContent("Hi", style: TextStyle(fontSize: 40, color: Color(hex: "#FF0000")!))), frame: Rect(x: 10, y: 10, width: 0, height: 0))
        transaction.insert(text, into: .page(fixture.page))
        transaction.finalize()
        transaction.convertToPaths([text.id])
        transaction.finalize()
        let layer = try #require(transaction[text.id])
        #expect(layer.vectorPath != nil)
        #expect(layer.style.fills.first?.color == Color(hex: "#FF0000"))
        #expect(layer.frame.width > 20 && layer.frame.height > 20)
    }

    @Test func booleanOperations() throws {
        // Lower 10…110 and Upper 50…150 overlap in a 60×60 square.
        for (operation, area) in [(BooleanOperation.union, 16400.0), (.subtract, 6400), (.intersect, 3600), (.difference, 12800)] {
            var transaction = Transaction(fixture.document)
            let combined = transaction.combine([fixture.lower, fixture.upper], operation)
            let id = try #require(combined)
            transaction.finalize()
            #expect(transaction[fixture.lower] == nil && transaction[fixture.upper] == nil)
            #expect(transaction[fixture.artboard]?.children == [id])
            let bitmap = try Bitmap(width: 600, height: 500)
            CanvasRenderer().draw(page: transaction.document.pages[0], of: transaction.document, in: bitmap.context)
            var painted = 0.0
            for y in 100..<400 { for x in 100..<400 where bitmap.color(x: x, y: y) == .black { painted += 1 } }
            #expect(abs(painted - area) < area * 0.02, "\(operation): \(painted) vs \(area)")
        }
    }

    @Test func outlineStrokeMakesAFilledShape() throws {
        var transaction = Transaction(fixture.document)
        transaction.update(fixture.oval) { $0.style = Style(borders: [Border(Color(hex: "#00FF00")!, width: 4)]) }
        let outlines = transaction.outlineBorders([fixture.oval])
        transaction.finalize()
        let outline = try #require(outlines.first.flatMap { transaction[$0] })
        #expect(transaction[fixture.oval] == nil)  // it had no fill, so the outline replaces it
        #expect(outline.style.fills.first?.color == Color(hex: "#00FF00"))
        #expect(outline.frame == Rect(x: 598, y: 98, width: 54, height: 54))
    }

    @Test func masksClipTheLayersAboveThem() throws {
        var document = fixture.document
        // Lower becomes a mask: Upper (above it) only shows where they overlap.
        document.layers[fixture.lower]?.isMask = true
        document.layers[fixture.lower]?.style.fills = [Fill(.white)]
        let bitmap = try Bitmap(width: 600, height: 500)
        CanvasRenderer().draw(page: document.pages[0], of: document, in: bitmap.context)
        #expect(bitmap.color(x: 200, y: 200) == .black)    // overlap
        #expect(bitmap.color(x: 240, y: 240) == .white)    // Upper outside the mask: not drawn
        let page = try #require(document.page(fixture.page))
        #expect(HitTester(document: document).path(at: CGPoint(x: 240, y: 240), on: page) == [fixture.artboard])
    }

    @Test func maskCommandGroupsWithTheBottomLayerAsMask() throws {
        let editor = DocumentEditor(document: fixture.document)
        editor.select([fixture.lower, fixture.upper])
        editor.maskSelection()
        let group = try #require(editor.selectedLayers.first)
        #expect(group.kind == .group && group.name == "Mask Group")
        #expect(editor.document.layers[group.children[0]]?.isMask == true)
        try editor.document.validate()
    }

    @Test func pathsRoundTripThroughTheFile() throws {
        var transaction = Transaction(fixture.document)
        _ = triangle(in: &transaction)
        transaction.update(fixture.oval) { $0.isMask = true }
        let data = try DocumentArchive.encode(transaction.document)
        #expect(try DocumentArchive.decode(data) == transaction.document)
    }

    @Test func svgWritesPathsAndFillRules() throws {
        var transaction = Transaction(fixture.document)
        let combined = transaction.combine([fixture.lower, fixture.upper], .difference)
        let id = try #require(combined)
        transaction.finalize()
        let svg = try #require(SVGWriter.svg(of: id, in: transaction.document))
        #expect(svg.contains("<path fill-rule=\"evenodd\""))
    }
}

@Suite struct PathEditingTests {
    private var square: VectorPath {
        VectorPath(subpaths: [Subpath(points: [
            PathPoint(CGPoint(x: 0, y: 0)), PathPoint(CGPoint(x: 100, y: 0)),
            PathPoint(CGPoint(x: 100, y: 100)), PathPoint(CGPoint(x: 0, y: 100)),
        ], isClosed: true)])
    }

    @Test func findsTheNearestSegment() throws {
        let hit = try #require(square.segment(near: CGPoint(x: 50, y: 3), tolerance: 5))
        #expect(hit.start == PointRef(subpath: 0, index: 0))
        #expect(abs(hit.t - 0.5) < 0.02)
        // The closing segment, from the last point back to the first.
        #expect(square.segment(near: CGPoint(x: 2, y: 50), tolerance: 5)?.start == PointRef(subpath: 0, index: 3))
        #expect(square.segment(near: CGPoint(x: 50, y: 50), tolerance: 5) == nil)
    }

    @Test func splittingKeepsTheShape() throws {
        var path = VectorPath(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 100, height: 100), transform: nil))
        let before = path.cgPath().boundingBoxOfPath
        let insertedRef = path.insertPoint(on: PointRef(subpath: 0, index: 0), at: 0.5)
        let inserted = try #require(insertedRef)
        #expect(path.subpaths[0].points.count == 5)
        #expect(path[inserted]?.mode == .asymmetric)
        let after = path.cgPath().boundingBoxOfPath
        #expect(abs(after.width - before.width) < 0.01 && abs(after.height - before.height) < 0.01)

        var straight = square
        let cornerRef = straight.insertPoint(on: PointRef(subpath: 0, index: 0), at: 0.25)
        let corner = try #require(cornerRef)
        #expect(abs((straight[corner]?.point.x ?? 0) - 25) < 0.0001)
        #expect(straight[corner]?.curveIn == nil)
    }

    @Test func removingPointsDropsTinySubpaths() {
        var path = square
        path.removePoints([PointRef(subpath: 0, index: 1)])
        #expect(path.subpaths[0].points.count == 3)
        path.removePoints([PointRef(subpath: 0, index: 0), PointRef(subpath: 0, index: 1)])
        #expect(path.isEmpty)
    }
}

@Suite struct MaskExportTests {
    @Test func svgClipsLayersAboveAMask() throws {
        let fixture = Fixture()
        var document = fixture.document
        document.layers[fixture.lower]?.isMask = true
        let svg = try #require(SVGWriter.svg(of: fixture.artboard, in: document))
        #expect(svg.contains("<clipPath id=\"mask"))
        // Upper comes after the mask and inside its clipping group.
        let maskGroup = try #require(svg.range(of: "<g clip-path=\"url(#mask"))
        let upper = try #require(svg.range(of: "x=\"50\" y=\"50\""))
        #expect(maskGroup.lowerBound < upper.lowerBound)
    }
}
