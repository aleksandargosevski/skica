import CoreGraphics
import Foundation
import Testing
@testable import SkicaCore
@testable import SkicaRender

@Suite struct SVGImportTests {
    private func importSVG(_ svg: String) throws -> (Document, LayerID) {
        let clipboard = try SVGImporter.clipboard(from: Data(svg.utf8), name: "Icon")
        let editor = DocumentEditor(document: Document())
        editor.paste(clipboard)
        let group = try #require(editor.selection.first)
        try editor.document.validate()
        return (editor.document, group)
    }

    private func render(_ document: Document, width: Int = 200, height: Int = 200) throws -> Bitmap {
        let bitmap = try Bitmap(width: width, height: height)
        CanvasRenderer().draw(page: document.pages[0], of: document, in: bitmap.context)
        return bitmap
    }

    private func layer(named name: String, in document: Document) throws -> Layer {
        try #require(document.layers.values.first { $0.name == name })
    }

    @Test func shapesBecomeNativeLayers() throws {
        let (document, group) = try importSVG("""
        <svg xmlns="http://www.w3.org/2000/svg" width="200" height="200" viewBox="0 0 100 100">
          <rect id="box" x="10" y="10" width="40" height="20" rx="4" fill="#ff0000"/>
          <circle id="dot" cx="75" cy="25" r="10" fill="rgb(0, 0, 255)" stroke="black" stroke-width="2"/>
          <g transform="translate(0 50)" opacity="0.5">
            <path id="tri" d="M10 10 L40 10 L25 40 Z" fill="lime"/>
          </g>
        </svg>
        """)
        // The view box scales everything by 2.
        let box = try layer(named: "box", in: document)
        #expect(box.kind == .rectangle(cornerRadius: 8))
        #expect(document.worldBounds(of: [box.id]) == CGRect(x: 20, y: 20, width: 80, height: 40))
        #expect(box.style.fills.first?.color == Color(hex: "#FF0000"))
        let dot = try layer(named: "dot", in: document)
        #expect(dot.kind == .oval)
        #expect(dot.style.borders.first?.width == 4)
        let triangle = try layer(named: "tri", in: document)
        #expect(triangle.vectorPath?.subpaths.first?.points.count == 3)
        #expect(document.layers[triangle.parent!]?.opacity == 0.5)
        #expect(document.layers[group]?.kind == .group)

        let bitmap = try render(document)
        #expect(bitmap.color(x: 50, y: 40) == Color(hex: "#FF0000"))
        #expect(bitmap.color(x: 150, y: 50) == Color(hex: "#0000FF"))
    }

    @Test func pathCommandsArcsAndRelativeCoordinates() {
        let square = SVGPathData.path("m10 10h20v20h-20z").boundingBoxOfPath
        #expect(square == CGRect(x: 10, y: 10, width: 20, height: 20))
        let arc = SVGPathData.path("M0 50 A50 50 0 0 1 100 50").boundingBoxOfPath
        #expect(abs(arc.minY - 0) < 0.5 && abs(arc.height - 50) < 0.5)
        // Numbers running together, implicit lineto after moveto, smooth curves.
        let packed = SVGPathData.path("M0,0 10-5.5.5 20S30 10 40 0").boundingBoxOfPath
        #expect(packed.maxX == 40)
        #expect(NumberScanner.numbers(in: "1e2-3.5.5") == [100, -3.5, 0.5])
    }

    @Test func cssClassesGradientsAndUse() throws {
        let (document, _) = try importSVG("""
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="100" height="100">
          <defs>
            <style>.accent { fill: #00ff00 } #b { fill: url(#fade) }</style>
            <linearGradient id="fade" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#000"/><stop offset="100%" stop-color="#fff"/></linearGradient>
            <rect id="tile" width="10" height="10"/>
          </defs>
          <rect id="a" class="accent" width="10" height="10" fill="red"/>
          <rect id="b" x="20" width="50" height="10"/>
          <use id="copy" xlink:href="#tile" x="80" y="80" style="fill: blue"/>
        </svg>
        """)
        #expect(try layer(named: "a", in: document).style.fills.first?.color == Color(hex: "#00FF00"))
        let gradient = try #require(try layer(named: "b", in: document).style.fills.first?.gradient)
        #expect(gradient.from == UnitPoint(x: 0, y: 0) && gradient.to == UnitPoint(x: 1, y: 0))
        #expect(gradient.stops.count == 2)
        let copy = try layer(named: "copy", in: document)
        let tile = try #require(document.layers[copy.children.first!])
        #expect(tile.style.fills.first?.color == Color(hex: "#0000FF"))
        #expect(document.worldBounds(of: [copy.id])?.minX == 80)
    }

    @Test func rotatedShapesBecomePaths() throws {
        let (document, _) = try importSVG("""
        <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
          <rect id="r" x="25" y="25" width="50" height="50" transform="rotate(45 50 50)"/>
        </svg>
        """)
        let rotated = try layer(named: "r", in: document)
        #expect(rotated.vectorPath != nil)
        #expect(abs(rotated.frame.width - 70.71) < 0.1)
    }

    @Test func textKeepsItsRunsAndBaseline() throws {
        let (document, _) = try importSVG("""
        <svg xmlns="http://www.w3.org/2000/svg" width="300" height="100">
          <text id="t" x="10" y="50" font-family="Helvetica" font-size="20" fill="#333">Hello <tspan font-weight="bold">world</tspan></text>
        </svg>
        """)
        let text = try layer(named: "t", in: document)
        let content = try #require(text.textContent)
        #expect(content.string == "Hello world")
        #expect(content.runs.count == 2)
        #expect(content.leadingStyle.fontSize == 20)
        let bounds = try #require(document.worldBounds(of: [text.id]))
        #expect(bounds.minY < 50 && bounds.minY > 25)
    }

    @Test func badInputFailsWithAMessage() {
        #expect(throws: ImportError.self) { try SVGImporter.clipboard(from: Data("not xml".utf8)) }
        #expect(throws: ImportError.self) { try SVGImporter.clipboard(from: Data("<html></html>".utf8)) }
        #expect(throws: ImportError.self) { try SVGImporter.clipboard(from: Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8)) }
    }

    @Test func exportedSVGImportsBackLookingTheSame() throws {
        let fixture = Fixture()
        let svg = try #require(SVGWriter.svg(of: fixture.artboard, in: fixture.document))
        let clipboard = try SVGImporter.clipboard(from: Data(svg.utf8))
        var document = Document()
        var transaction = Transaction(document)
        _ = transaction.paste(clipboard, into: .page(document.pages[0].id))
        transaction.finalize()
        document = transaction.document

        let original = try Bitmap(width: 400, height: 300)
        original.context.translateBy(x: -100, y: -100)
        CanvasRenderer().draw(page: fixture.document.pages[0], of: fixture.document, in: original.context)
        let imported = try render(document, width: 400, height: 300)
        for (x, y) in [(20, 20), (60, 60), (150, 150), (300, 250)] {
            #expect(imported.color(x: x, y: y) == original.color(x: x, y: y), "\(x),\(y)")
        }
    }
}
