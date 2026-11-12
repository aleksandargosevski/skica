import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import SkicaCore
@testable import SkicaRender

@Suite struct CropTests {
    /// A 100×100 image, red on the left half and blue on the right, at 0,0 on the page.
    private func imageDocument() throws -> (Document, LayerID) {
        let bitmap = try Bitmap(width: 100, height: 100)
        bitmap.context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        bitmap.context.fill(CGRect(x: 0, y: 0, width: 50, height: 100))
        bitmap.context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        bitmap.context.fill(CGRect(x: 50, y: 0, width: 50, height: 100))
        let data = try Exporter.encode(try #require(bitmap.context.makeImage()), as: .png)
        var transaction = Transaction(Document())
        let hash = transaction.addImage(data)
        let layer = Layer(name: "Photo", kind: .image(hash: hash), frame: Rect(x: 0, y: 0, width: 100, height: 100))
        transaction.insert(layer, into: .page(transaction.document.pages[0].id))
        return (transaction.document, layer.id)
    }

    private func render(_ document: Document) throws -> Bitmap {
        let bitmap = try Bitmap(width: 100, height: 100)
        CanvasRenderer().draw(page: document.pages[0], of: document, in: bitmap.context)
        return bitmap
    }

    @Test func croppingKeepsTheImageInPlace() throws {
        let (document, id) = try imageDocument()
        var transaction = Transaction(document)
        transaction.setCrop(id, frame: CGRect(x: 50, y: 0, width: 50, height: 100), imageRect: CGRect(x: 0, y: 0, width: 100, height: 100))
        let layer = try #require(transaction[id])
        #expect(layer.frame == Rect(x: 50, y: 0, width: 50, height: 100))
        #expect(layer.imageCrop == Rect(x: -50, y: 0, width: 100, height: 100))
        let bitmap = try render(transaction.document)
        let shown = try #require(bitmap.color(x: 75, y: 50))
        #expect(shown.blue > 200 && shown.red < 30)   // the blue half (colors pass through the PNG's profile)
        #expect(bitmap.color(x: 25, y: 50)?.alpha == 0)   // cut off
    }

    @Test func theCropStaysInsideTheImage() throws {
        let (document, id) = try imageDocument()
        var transaction = Transaction(document)
        transaction.setCrop(id, frame: CGRect(x: -20, y: 40, width: 200, height: 20), imageRect: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(transaction[id]?.frame == Rect(x: 0, y: 40, width: 100, height: 20))
        // Sliding the image cannot uncover the crop.
        transaction.moveCroppedImage(id, by: CGVector(dx: 0, dy: 500))
        #expect(transaction[id]?.imageRectInParent == CGRect(x: 0, y: 40, width: 100, height: 100))
        transaction.moveCroppedImage(id, by: CGVector(dx: 0, dy: -30))
        #expect(transaction[id]?.imageRectInParent == CGRect(x: 0, y: 10, width: 100, height: 100))
    }

    @Test func resizingScalesTheCropAndResetShowsEverything() throws {
        let (document, id) = try imageDocument()
        var cropping = Transaction(document)
        cropping.setCrop(id, frame: CGRect(x: 50, y: 0, width: 50, height: 100), imageRect: CGRect(x: 0, y: 0, width: 100, height: 100))
        var resizing = Transaction(cropping.document)
        resizing.update(id) { $0.frame.width = 100 }
        resizing.finalize()
        #expect(resizing[id]?.imageCrop == Rect(x: -100, y: 0, width: 200, height: 100))

        resizing.resetCrop([id])
        #expect(resizing[id]?.imageCrop == nil)
        #expect(resizing[id]?.frame == Rect(x: -50, y: 0, width: 200, height: 100))
    }

    @Test func cropsExportToSVGAndRoundTrip() throws {
        let (document, id) = try imageDocument()
        var transaction = Transaction(document)
        transaction.setCrop(id, frame: CGRect(x: 0, y: 0, width: 50, height: 50), imageRect: CGRect(x: 0, y: 0, width: 100, height: 100))
        let svg = try #require(SVGWriter.svg(of: id, in: transaction.document))
        #expect(svg.contains("clip-path") && svg.contains("width=\"100\""))
        let data = try DocumentArchive.encode(transaction.document)
        #expect(try DocumentArchive.decode(data).layers[id]?.imageCrop == transaction[id]?.imageCrop)
    }
}
