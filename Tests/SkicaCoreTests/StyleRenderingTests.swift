import CoreGraphics
import Foundation
import Testing
@testable import SkicaCore
@testable import SkicaRender

@Suite struct StyleRenderingTests {
    /// One 40×40 rectangle at (20, 20) on an otherwise empty page.
    private func render(_ style: Style, scale: CGFloat = 1, kind: LayerKind = .rectangle(cornerRadius: 0)) throws -> Bitmap {
        var transaction = Transaction(Document())
        transaction.insert(Layer(name: "Shape", kind: kind, frame: Rect(x: 20, y: 20, width: 40, height: 40), style: style), into: .page(transaction.document.pages[0].id))
        let document = transaction.document
        let size = Int(100 * scale)
        let bitmap = try Bitmap(width: size, height: size)
        bitmap.context.scaleBy(x: scale, y: scale)
        CanvasRenderer().draw(page: document.pages[0], of: document, in: bitmap.context)
        return bitmap
    }

    private let red = Color(hex: "#FF0000")!
    private let blue = Color(hex: "#0000FF")!

    @Test func linearGradientsRunTopToBottom() throws {
        let gradient = Gradient(stops: [GradientStop(position: 0, color: red), GradientStop(position: 1, color: blue)])
        let bitmap = try render(Style(fills: [Fill(.white, gradient: gradient)]))
        let top = try #require(bitmap.color(x: 40, y: 21))
        let bottom = try #require(bitmap.color(x: 40, y: 58))
        #expect(top.red > 230 && top.blue < 25)
        #expect(bottom.blue > 230 && bottom.red < 25)
    }

    @Test func gradientAngleRoundTrips() {
        var gradient = Gradient(stops: [])
        gradient.angle = 0
        #expect(gradient.from == UnitPoint(x: 0, y: 0.5))
        #expect(abs(gradient.angle) < 0.0001)
        gradient.angle = 90
        #expect(abs(gradient.angle - 90) < 0.0001)
    }

    @Test func bordersSitInsideCenteredOrOutside() throws {
        let inside = try render(Style(borders: [Border(red, width: 4, position: .inside)]))
        #expect(inside.color(x: 21, y: 40) == red)
        #expect(inside.color(x: 18, y: 40)?.alpha == 0)

        let outside = try render(Style(borders: [Border(red, width: 4, position: .outside)]))
        #expect(outside.color(x: 18, y: 40) == red)
        #expect(outside.color(x: 21, y: 40)?.alpha == 0)
    }

    /// Shadows must scale with zoom: at 2× a 10-unit offset is 20 pixels.
    @Test(arguments: [1.0, 2.0])
    func dropShadowsFollowZoom(scale: Double) throws {
        let shadow = Shadow(color: blue, x: 0, y: 10, blur: 0)
        let bitmap = try render(Style(fills: [Fill(red)], shadows: [shadow]), scale: scale)
        let s = CGFloat(scale)
        #expect(bitmap.color(x: Int(40 * s), y: Int(65 * s)) == blue)   // below the shape, inside the offset shadow
        #expect(bitmap.color(x: Int(40 * s), y: Int(75 * s))?.alpha == 0) // past the shadow
        #expect(bitmap.color(x: Int(40 * s), y: Int(40 * s)) == red)    // the shape itself is on top
    }

    @Test func dropShadowsDoNotShowThroughTransparentFills() throws {
        let bitmap = try render(Style(shadows: [Shadow(color: blue, x: 0, y: 10, blur: 0)]))
        #expect(bitmap.color(x: 40, y: 65) == blue)
        #expect(bitmap.color(x: 40, y: 40)?.alpha == 0)
    }

    @Test(arguments: [1.0, 2.0])
    func blurredShadowsSpreadEvenlyAroundTheOffset(scale: Double) throws {
        let bitmap = try render(Style(fills: [Fill(red)], shadows: [Shadow(color: .black, x: 0, y: 10, blur: 8)]), scale: scale)
        let s = CGFloat(scale)
        let below = try #require(bitmap.color(x: Int(40 * s), y: Int(68 * s)))
        let above = try #require(bitmap.color(x: Int(40 * s), y: Int(16 * s)))
        let side = try #require(bitmap.color(x: Int(16 * s), y: Int(50 * s)))
        #expect(below.alpha > 100)
        #expect(above.alpha < 20)
        #expect(side.alpha > 0 && side.alpha < below.alpha)
    }

    @Test func innerShadowsStayInside() throws {
        let bitmap = try render(Style(fills: [Fill(.white)], innerShadows: [Shadow(color: blue, x: 0, y: 6, blur: 0)]))
        #expect(bitmap.color(x: 40, y: 22) == blue)
        #expect(bitmap.color(x: 40, y: 40) == .white)
        #expect(bitmap.color(x: 40, y: 15)?.alpha == 0)
    }

    @Test func blurSoftensEdges() throws {
        let sharp = try render(Style(fills: [Fill(red)]))
        let blurred = try render(Style(fills: [Fill(red)], blur: Blur(radius: 6)))
        #expect(sharp.color(x: 17, y: 40)?.alpha == 0)
        #expect((blurred.color(x: 17, y: 40)?.alpha ?? 0) > 0)
        #expect((blurred.color(x: 40, y: 40)?.red ?? 0) > 200)
    }

    @Test func blendModesMixWithWhatIsBelow() throws {
        var transaction = Transaction(Document())
        let page = transaction.document.pages[0].id
        transaction.insert(Layer(name: "Below", kind: .rectangle(cornerRadius: 0), frame: Rect(x: 0, y: 0, width: 100, height: 100), style: Style(fills: [Fill(Color(hex: "#808080")!)])), into: .page(page))
        transaction.insert(Layer(name: "Above", kind: .rectangle(cornerRadius: 0), frame: Rect(x: 0, y: 0, width: 100, height: 100), style: Style(fills: [Fill(Color(hex: "#808080")!)], blendMode: .multiply)), into: .page(page))
        let bitmap = try Bitmap(width: 100, height: 100)
        CanvasRenderer().draw(page: transaction.document.pages[0], of: transaction.document, in: bitmap.context)
        let mixed = try #require(bitmap.color(x: 50, y: 50))
        #expect(mixed.red < 80)
    }

    @Test func formatOneStylesStillDecode() throws {
        let json = ##"{"fills":[{"isEnabled":true,"color":"#FF0000"}],"borders":[{"isEnabled":true,"color":"#000000","width":2}]}"##
        let style = try JSONDecoder().decode(Style.self, from: Data(json.utf8))
        #expect(style.fills == [Fill(red)])
        #expect(style.borders == [Border(.black, width: 2)])
        #expect(style.shadows.isEmpty && style.blendMode == .normal)
    }
}
