import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import SkicaCore
@testable import SkicaRender

/// A solid-color PNG of the given pixel size and density.
func makePNG(width: Int, height: Int, color: CGColor = CGColor(srgbRed: 0, green: 0.5, blue: 1, alpha: 1), dpi: Double = 72) throws -> Data {
    let bitmap = try Bitmap(width: width, height: height)
    bitmap.context.setFillColor(color)
    bitmap.context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(bitmap.context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

@Suite struct ImageTests {
    let fixture = Fixture()

    @Test func naturalSizeAccountsForDensity() throws {
        #expect(ImageData.naturalSize(of: try makePNG(width: 200, height: 100)) == CGSize(width: 200, height: 100))
        #expect(ImageData.naturalSize(of: try makePNG(width: 200, height: 100, dpi: 144)) == CGSize(width: 100, height: 50))
        #expect(ImageData.naturalSize(of: Data("not an image".utf8)) == nil)
        #expect(ImageData.fileExtension(of: try makePNG(width: 2, height: 2)) == "png")
    }

    @Test func insertingFitsTheArtboardAndRendersThePixels() throws {
        let editor = DocumentEditor(document: fixture.document)
        let png = try makePNG(width: 1000, height: 500)
        let id = try #require(editor.insertImage(png, named: "Photo", centeredAt: CGPoint(x: 300, y: 250)))
        let layer = try #require(editor.document.layers[id])
        #expect(layer.parent == fixture.artboard)
        #expect(layer.frame.width == 360)   // 90% of the 400-wide artboard
        #expect(layer.frame.height == 180)

        let bitmap = try Bitmap(width: 700, height: 500)
        CanvasRenderer().draw(page: editor.page, of: editor.document, in: bitmap.context)
        let pixel = try #require(bitmap.color(x: 300, y: 250))
        #expect(pixel.blue > 240 && pixel.red < 10)
    }

    @Test func imagesSurviveSavingAndUnusedOnesAreDropped() throws {
        let editor = DocumentEditor(document: fixture.document)
        let kept = try makePNG(width: 10, height: 10)
        let dropped = try makePNG(width: 20, height: 20)
        editor.insertImage(kept, named: "Kept", centeredAt: CGPoint(x: 300, y: 250))
        let removed = try #require(editor.insertImage(dropped, named: "Dropped", centeredAt: CGPoint(x: 300, y: 250)))
        editor.select([removed])
        editor.deleteSelection()

        let reopened = try DocumentArchive.decode(DocumentArchive.encode(editor.document))
        #expect(reopened.images.keys.sorted() == [ImageData.hash(of: kept)])
        #expect(reopened.layers == editor.document.layers)
    }

    @Test func copiedImagesPasteIntoOtherDocuments() throws {
        let source = DocumentEditor(document: fixture.document)
        let png = try makePNG(width: 10, height: 10)
        let id = try #require(source.insertImage(png, named: "Photo", centeredAt: CGPoint(x: 300, y: 250)))
        let clipboard = try LayerClipboard.decode(LayerClipboard(copying: [id], from: source.document).encoded())

        let target = DocumentEditor(document: Document())
        target.paste(clipboard)
        let pasted = try #require(target.selectedLayers.first?.imageHash)
        #expect(target.document.images[pasted] == png)
    }
}
