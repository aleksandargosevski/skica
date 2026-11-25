import CoreGraphics
import Foundation
import Testing
@testable import SkicaCore

@Suite struct IsolationTests {
    let fixture = Fixture()

    @Test func hidesEverythingButTheSelectionAndItsContainers() throws {
        let page = try #require(fixture.document.page(fixture.page))
        let isolation = Isolation(keeping: [fixture.upper], on: page, in: fixture.document)
        #expect(isolation.hidden == [fixture.lower, fixture.oval])

        let shown = isolation.apply(to: fixture.document)
        #expect(shown.layers[fixture.artboard]?.isVisible == true)
        #expect(shown.layers[fixture.upper]?.isVisible == true)
        #expect(shown.layers[fixture.lower]?.isVisible == false)
        #expect(shown.layers[fixture.oval]?.isVisible == false)
        #expect(fixture.document.layers[fixture.lower]?.isVisible == true)
    }

    @Test func keepsTheContentsOfAnIsolatedContainer() throws {
        let page = try #require(fixture.document.page(fixture.page))
        let isolation = Isolation(keeping: [fixture.artboard], on: page, in: fixture.document)
        #expect(isolation.hidden == [fixture.oval])
        #expect(!isolation.hides(fixture.lower, in: fixture.document))
    }

    @Test func layersInsideHiddenContainersCountAsHidden() throws {
        let page = try #require(fixture.document.page(fixture.page))
        let isolation = Isolation(keeping: [fixture.oval], on: page, in: fixture.document)
        #expect(isolation.hidden == [fixture.artboard])
        #expect(isolation.hides(fixture.upper, in: fixture.document))
        #expect(!isolation.hides(fixture.oval, in: fixture.document))
    }
}

@Suite struct DistanceTests {
    @Test func measuresTheGapBetweenLayersSideBySide() {
        let distances = Distances(from: CGRect(x: 0, y: 0, width: 100, height: 100), to: CGRect(x: 130, y: 50, width: 100, height: 100))
        #expect(distances.lines == [Distances.Line(start: CGPoint(x: 100, y: 75), end: CGPoint(x: 130, y: 75), value: 30)])
        #expect(distances.extensions.isEmpty)
    }

    @Test func measuresBothGapsDiagonallyWithExtensions() {
        let distances = Distances(from: CGRect(x: 0, y: 0, width: 10, height: 10), to: CGRect(x: 20, y: 30, width: 10, height: 10))
        #expect(distances.lines.map(\.value) == [10, 20])
        #expect(distances.extensions.count == 2)
    }

    @Test func measuresFromInnerEdgesToTheContainer() {
        let distances = Distances(from: CGRect(x: 10, y: 20, width: 50, height: 50), to: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(distances.lines.map(\.value) == [10, 40, 20, 30])
    }

    @Test func targetsTheHoveredLayerOrTheContainer() {
        let fixture = Fixture()
        let document = fixture.document
        #expect(Distances.target(for: [fixture.upper], hovered: fixture.lower, in: document) == fixture.lower)
        #expect(Distances.target(for: [fixture.upper], hovered: fixture.upper, in: document) == fixture.artboard)
        #expect(Distances.target(for: [fixture.upper], hovered: nil, in: document) == fixture.artboard)
        #expect(Distances.target(for: [fixture.oval], hovered: nil, in: document) == nil)
        #expect(Distances.target(for: [], hovered: fixture.oval, in: document) == nil)
    }
}
