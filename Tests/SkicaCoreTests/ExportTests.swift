import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import SkicaCore
@testable import SkicaRender

@Suite struct ExportTests {
    let fixture = Fixture()

    private func decode(_ data: Data) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> Color {
        let bitmap = try Bitmap(width: image.width, height: image.height)
        bitmap.context.saveGState()
        bitmap.context.translateBy(x: 0, y: CGFloat(image.height))
        bitmap.context.scaleBy(x: 1, y: -1)
        bitmap.context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        bitmap.context.restoreGState()
        return try #require(bitmap.color(x: x, y: y))
    }

    @Test func presetSizesParseAndPrint() {
        #expect(ExportPreset.Size(parsing: "2x") == .scale(2))
        #expect(ExportPreset.Size(parsing: "0.5") == .scale(0.5))
        #expect(ExportPreset.Size(parsing: "512w") == .width(512))
        #expect(ExportPreset.Size(parsing: "300H") == .height(300))
        #expect(ExportPreset.Size(parsing: "big") == nil)
        #expect(ExportPreset.Size.width(512).description == "512w")
        #expect(ExportPreset.next(after: [ExportPreset()]) == ExportPreset(size: .scale(2), suffix: "@2x"))
    }

    @Test func layersWithoutExportsStillDecode() throws {
        let json = #"{"id":"a","name":"A","kind":{"oval":{}},"frame":{"x":0,"y":0,"width":1,"height":1},"rotation":0,"opacity":1,"isVisible":true,"isLocked":false,"style":{},"children":[]}"#
        let layer = try JSONDecoder().decode(Layer.self, from: Data(json.utf8))
        #expect(layer.exports.isEmpty)
    }

    @Test func boundsCoverArtboardsAndShadows() throws {
        #expect(fixture.document.exportBounds(of: fixture.artboard) == CGRect(x: 100, y: 100, width: 400, height: 300))
        var document = fixture.document
        document.layers[fixture.oval]?.style.shadows = [Shadow(x: 0, y: 10, blur: 0)]
        let bounds = try #require(document.exportBounds(of: fixture.oval))
        #expect(bounds.minY == 90 && bounds.maxY == 160)
    }

    @Test func rasterExportsAtTheRequestedSize() throws {
        let files = try Exporter.files(for: [fixture.artboard], in: fixture.document, presets: [
            ExportPreset(), ExportPreset(size: .scale(2), suffix: "@2x"), ExportPreset(size: .width(100), suffix: "-small", format: .jpg),
        ])
        #expect(files.map(\.path) == ["Board.png", "Board@2x.png", "Board-small.jpg"])
        let one = try decode(files[0].data)
        let two = try decode(files[1].data)
        let small = try decode(files[2].data)
        #expect((one.width, one.height) == (400, 300))
        #expect((two.width, two.height) == (800, 600))
        #expect((small.width, small.height) == (100, 75))
        // Lower sits at (10, 10) in the artboard, black on white.
        #expect(try pixel(one, x: 20, y: 20) == .black)
        #expect(try pixel(one, x: 300, y: 250) == .white)
    }

    @Test(arguments: [ExportPreset.Format.webp, .heic, .avif])
    func modernFormatsDecode(format: ExportPreset.Format) throws {
        let data = try Exporter.data(for: fixture.artboard, in: fixture.document, preset: ExportPreset(format: format))
        let image = try decode(data)
        #expect((image.width, image.height) == (400, 300))
        let dark = try pixel(image, x: 20, y: 20)
        #expect(dark.red < 30 && dark.green < 30)
    }

    @Test func transparentAreasStayTransparentExceptInJPEG() throws {
        let png = try decode(Exporter.data(for: fixture.oval, in: fixture.document, preset: ExportPreset()))
        #expect(try pixel(png, x: 1, y: 1).alpha == 0)
        let jpg = try decode(Exporter.data(for: fixture.oval, in: fixture.document, preset: ExportPreset(format: .jpg)))
        #expect(try pixel(jpg, x: 1, y: 1).red > 250)
    }

    @Test func pdfHasOnePagePerLayer() throws {
        let data = try Exporter.pdf(of: [fixture.artboard, fixture.oval], in: fixture.document)
        let pdf = try #require(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        #expect(pdf.numberOfPages == 2)
        #expect(pdf.page(at: 1)?.getBoxRect(.mediaBox).size == CGSize(width: 400, height: 300))
    }

    @Test func layerNamesBecomeFoldersAndDuplicatesAreNumbered() throws {
        var document = fixture.document
        document.layers[fixture.lower]?.name = "Icons/Home"
        document.layers[fixture.upper]?.name = "Icons/Home"
        let files = try Exporter.files(for: [fixture.lower, fixture.upper], in: document)
        #expect(files.map(\.path) == ["Icons/Home.png", "Icons/Home 2.png"])
    }

    @Test func svgUsesRealElementsAndPageCoordinates() throws {
        var document = fixture.document
        document.layers[fixture.upper]?.kind = .rectangle(cornerRadius: 8)
        document.layers[fixture.upper]?.style = Style(
            fills: [Fill(.black, gradient: Gradient(stops: [GradientStop(position: 0, color: .black), GradientStop(position: 1, color: .white)]))],
            borders: [Border(Color(hex: "#FF000080")!, width: 2, position: .inside, dashes: [4, 2])],
            shadows: [Shadow(x: 0, y: 4, blur: 8)]
        )
        let svg = try #require(SVGWriter.svg(of: fixture.artboard, in: document))
        #expect(svg.hasPrefix("<svg xmlns=\"http://www.w3.org/2000/svg\""))
        #expect(svg.contains("viewBox=\"100 100 400 300\""))
        #expect(svg.contains("<rect x=\"50\" y=\"50\" width=\"100\" height=\"100\" rx=\"8\" fill=\"url(#gradient"))
        #expect(svg.contains("<linearGradient"))
        #expect(svg.contains("stroke=\"#FF0000\" stroke-opacity=\"0.502\" stroke-width=\"4\""))
        #expect(svg.contains("stroke-dasharray=\"4 2\""))
        #expect(svg.contains("clip-path=\"url(#inside"))
        #expect(svg.contains("<feGaussianBlur"))
        #expect(svg.contains("<ellipse") == false)  // the oval is not on this artboard

        let oval = try #require(SVGWriter.svg(of: fixture.oval, in: document))
        #expect(oval.contains("<ellipse cx=\"625\" cy=\"125\" rx=\"25\" ry=\"25\" fill=\"#000000\"/>"))
    }

    @Test func svgTextKeepsLinesAndFonts() throws {
        var transaction = Transaction(Document())
        let style = TextStyle(fontName: "HelveticaNeue-Bold", fontSize: 20, color: Color(hex: "#112233")!)
        let text = Layer(name: "T", kind: .text(TextContent("One two three four five six", style: style, sizing: .autoHeight)), frame: Rect(x: 0, y: 0, width: 80, height: 0))
        transaction.insert(text, into: .page(transaction.document.pages[0].id))
        transaction.finalize()
        let svg = try #require(SVGWriter.svg(of: text.id, in: transaction.document))
        #expect(svg.contains("font-family=\"Helvetica Neue, sans-serif\""))
        #expect(svg.contains("font-weight=\"700\""))
        #expect(svg.contains("fill=\"#112233\""))
        #expect(svg.components(separatedBy: "<text ").count - 1 >= 3)  // wrapped onto several lines
    }

    @Test func svgEscapesText() {
        #expect(SVGWriter.escape("a < b & \"c\"") == "a &lt; b &amp; &quot;c&quot;")
        #expect(SVGWriter.number(1.23456) == "1.235")
        #expect(SVGWriter.number(2.0) == "2")
        #expect(SVGWriter.number(-0.5) == "-0.5")
    }
}
