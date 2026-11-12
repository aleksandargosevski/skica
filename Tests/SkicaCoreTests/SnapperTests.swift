import CoreGraphics
import Testing
@testable import SkicaCore

@Suite struct SnapperTests {
    let snapper = Snapper(targets: [CGRect(x: 100, y: 100, width: 100, height: 50)], threshold: 5)

    @Test func movesSnapToTheNearestEdgeOrCenter() {
        let result = snapper.snap(moving: CGRect(x: 203, y: 300, width: 40, height: 40))
        #expect(result.offset == CGVector(dx: -3, dy: 0))
        #expect(result.guides == [SnapGuide(start: CGPoint(x: 200, y: 100), end: CGPoint(x: 200, y: 340))])

        let centered = snapper.snap(moving: CGRect(x: 128, y: 104, width: 40, height: 40))
        #expect(centered.offset == CGVector(dx: 2, dy: 1))   // centers line up on both axes
    }

    @Test func farAwayBoxesDoNotSnap() {
        let result = snapper.snap(moving: CGRect(x: 400, y: 400, width: 10, height: 10))
        #expect(result.offset == .zero)
        #expect(result.guides.isEmpty)
    }

    @Test func resizingSnapsOnlyTheDraggedEdges() {
        let result = snapper.snap(edgesOf: CGRect(x: 0, y: 0, width: 98, height: 98), movingX: 1, movingY: 0)
        #expect(result.box == CGRect(x: 0, y: 0, width: 100, height: 98))

        let left = snapper.snap(edgesOf: CGRect(x: 197, y: 0, width: 50, height: 10), movingX: -1, movingY: 0)
        #expect(left.box == CGRect(x: 200, y: 0, width: 47, height: 10))
    }

    @Test func pointsSnapOnBothAxes() {
        #expect(snapper.snap(point: CGPoint(x: 151, y: 148)).point == CGPoint(x: 150, y: 150))
    }

    @Test func targetsLeaveOutMovingLayersAndIncludeTheirArtboard() {
        let fixture = Fixture()
        let page = fixture.document.pages[0]
        let targets = Snapper.targets(for: [fixture.upper], on: page, in: fixture.document)
        #expect(targets.contains(CGRect(x: 100, y: 100, width: 400, height: 300)))  // the artboard
        #expect(targets.contains(CGRect(x: 110, y: 110, width: 100, height: 100)))  // lower
        #expect(!targets.contains(CGRect(x: 150, y: 150, width: 100, height: 100))) // upper itself
    }
}
