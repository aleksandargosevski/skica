import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import SkicaCore
@testable import SkicaRender

@Suite struct RendererTests {
    @Test func paintsLayersAtTheirAbsolutePositions() throws {
        let document = SampleDocuments.showcase()
        let bitmap = try Bitmap(width: 2505, height: 1072)
        CanvasRenderer().draw(page: document.pages[0], of: document, in: bitmap.context)

        #expect(bitmap.color(x: 200, y: 60) == Color(hex: "#5B5BD6"))   // iPhone header
        #expect(bitmap.color(x: 200, y: 500) == .white)                  // iPhone background
        #expect(bitmap.color(x: 473 + 56, y: 36) == Color(hex: "#5B5BD6")) // desktop logo, inside the artboard
        #expect(bitmap.color(x: 60, y: 1012) == Color(hex: "#30A46C"))   // loose oval
        #expect(bitmap.color(x: 300, y: 1000)?.alpha == 0)                // empty canvas

        if let path = ProcessInfo.processInfo.environment["SKICA_RENDER_OUTPUT"] {
            try bitmap.writePNG(to: URL(fileURLWithPath: path))
        }
    }

    /// Budget: a full redraw of 5,000 layers on a Retina-sized canvas stays well under a frame.
    @Test func drawsFiveThousandLayersQuickly() throws {
        let document = SampleDocuments.stress()
        let page = document.pages[0]
        let bounds = try #require(document.contentBounds(of: page))
        let bitmap = try Bitmap(width: 2880, height: 1800)
        bitmap.context.scaleBy(x: 2880 / bounds.width, y: 2880 / bounds.width)
        let renderer = CanvasRenderer()

        let clock = ContinuousClock()
        renderer.draw(page: page, of: document, in: bitmap.context)
        let runs = 5
        let elapsed = clock.measure {
            for _ in 0..<runs { renderer.draw(page: page, of: document, in: bitmap.context) }
        }
        let perFrame = elapsed / runs
        print("5,000 layers: \(perFrame) per frame")
        // CI runners are shared virtual machines without a real GPU; there the budget only
        // catches large regressions.
        let budget: Duration = ProcessInfo.processInfo.environment["CI"] == nil ? .milliseconds(100) : .milliseconds(400)
        #expect(perFrame < budget)
    }

    @Test func skipsHiddenLayers() throws {
        var document = SampleDocuments.showcase()
        let oval = try #require(document.layers.values.first { $0.name == "Loose Oval" })
        document.layers[oval.id]?.isVisible = false
        let bitmap = try Bitmap(width: 2505, height: 1072)
        CanvasRenderer().draw(page: document.pages[0], of: document, in: bitmap.context)
        #expect(bitmap.color(x: 60, y: 1012)?.alpha == 0)
    }
}

/// An sRGB bitmap whose coordinates match the canvas: y points down.
struct Bitmap {
    let context: CGContext
    let width: Int
    let height: Int

    init(width: Int, height: Int) throws {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw BitmapError.couldNotCreate }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        self.context = context
        self.width = width
        self.height = height
    }

    func color(x: Int, y: Int) -> Color? {
        guard let data = context.data, x >= 0, y >= 0, x < width, y < height else { return nil }
        let pixel = data.assumingMemoryBound(to: UInt8.self).advanced(by: (y * width + x) * 4)
        return Color(red: pixel[0], green: pixel[1], blue: pixel[2], alpha: pixel[3])
    }

    func writePNG(to url: URL) throws {
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw BitmapError.couldNotCreate }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw BitmapError.couldNotCreate }
    }

    enum BitmapError: Error { case couldNotCreate }
}
