import CoreGraphics
import Testing
@testable import SkicaCore

@Suite struct ViewportTests {
    @Test func convertsBetweenViewAndCanvas() {
        let viewport = Viewport(origin: CGPoint(x: 100, y: -50), zoom: 2)
        let canvas = viewport.toCanvas(CGPoint(x: 40, y: 20))
        #expect(canvas == CGPoint(x: 120, y: -40))
        #expect(viewport.toView(canvas) == CGPoint(x: 40, y: 20))
    }

    @Test func zoomKeepsTheAnchorInPlace() {
        var viewport = Viewport(origin: CGPoint(x: 10, y: 20), zoom: 1)
        let anchor = CGPoint(x: 300, y: 200)
        let before = viewport.toCanvas(anchor)
        viewport.setZoom(3.5, keeping: anchor)
        let after = viewport.toCanvas(anchor)
        #expect(abs(after.x - before.x) < 1e-9)
        #expect(abs(after.y - before.y) < 1e-9)
    }

    @Test func clampsZoom() {
        var viewport = Viewport(zoom: 1000)
        #expect(viewport.zoom == Viewport.zoomRange.upperBound)
        viewport.setZoom(0, keeping: .zero)
        #expect(viewport.zoom == Viewport.zoomRange.lowerBound)
    }

    @Test func panMovesContentWithTheDrag() {
        var viewport = Viewport(zoom: 2)
        viewport.pan(by: CGVector(dx: 20, dy: -10))
        #expect(viewport.origin == CGPoint(x: -10, y: 5))
    }

    @Test func fitCentersTheRect() {
        var viewport = Viewport()
        let rect = CGRect(x: 100, y: 100, width: 400, height: 200)
        viewport.fit(rect, in: CGSize(width: 1000, height: 1000), padding: 100)
        #expect(viewport.zoom == 2)
        let center = viewport.toCanvas(CGPoint(x: 500, y: 500))
        #expect(center == CGPoint(x: 300, y: 200))
    }

    @Test func fitRespectsMaxZoom() {
        var viewport = Viewport()
        viewport.fit(CGRect(x: 0, y: 0, width: 10, height: 10), in: CGSize(width: 800, height: 600), maxZoom: 1)
        #expect(viewport.zoom == 1)
    }

    @Test func stepsThroughZoomLevels() {
        #expect(Viewport.step(above: 1) == 2)
        #expect(Viewport.step(below: 1) == 0.5)
        #expect(Viewport.step(above: 0.7) == 1)
        #expect(Viewport.step(below: 0.7) == 0.5)
        #expect(Viewport.step(above: 256) == 256)
        #expect(Viewport.step(below: 0.01) == 0.01)
    }
}
