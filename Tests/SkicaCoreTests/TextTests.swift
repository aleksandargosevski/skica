import CoreGraphics
import Foundation
import Testing
@testable import SkicaCore
@testable import SkicaRender

@Suite struct TextTests {
    private func insertText(_ content: TextContent, frame: Rect = Rect(x: 10, y: 10, width: 0, height: 0)) -> (Transaction, LayerID) {
        var transaction = Transaction(Document())
        let layer = Layer(name: "Text", kind: .text(content), frame: frame)
        transaction.insert(layer, into: .page(transaction.document.pages[0].id))
        transaction.finalize()
        return (transaction, layer.id)
    }

    @Test func autoWidthTextFitsItsText() throws {
        let (transaction, id) = insertText(TextContent("Hello"))
        let frame = try #require(transaction[id]?.frame)
        #expect(frame.width > 20 && frame.width < 60)
        #expect(frame.height >= 16 && frame.height < 30)

        var longer = Transaction(transaction.document)
        longer.update(id) { $0.kind = .text(TextContent("Hello, wide world")) }
        longer.finalize()
        #expect((longer[id]?.frame.width ?? 0) > frame.width)
        #expect(longer[id]?.frame.height == frame.height)
    }

    @Test func emptyTextKeepsOneLineOfHeight() throws {
        let (transaction, id) = insertText(TextContent(""))
        #expect((transaction[id]?.frame.height ?? 0) > 10)
    }

    @Test func autoHeightTextWraps() throws {
        let words = String(repeating: "word ", count: 30)
        let (transaction, id) = insertText(TextContent(words, sizing: .autoHeight), frame: Rect(x: 0, y: 0, width: 100, height: 10))
        let frame = try #require(transaction[id]?.frame)
        #expect(frame.width == 100)
        #expect(frame.height > 100)
    }

    @Test func resizingSwitchesHowTextSizes() throws {
        let (transaction, id) = insertText(TextContent("Some text that is long enough to wrap"))
        var wider = Transaction(transaction.document)
        wider.update(id) { $0.frame.width = 80 }
        wider.finalize()
        #expect(wider[id]?.textContent?.sizing == .autoHeight)
        #expect((wider[id]?.frame.height ?? 0) > (transaction[id]?.frame.height ?? 0))

        var taller = Transaction(wider.document)
        taller.update(id) { $0.frame.height = 300 }
        taller.finalize()
        #expect(taller[id]?.textContent?.sizing == .fixed)
        #expect(taller[id]?.frame.height == 300)
    }

    @Test func centeredAutoWidthTextGrowsFromItsCenter() throws {
        let (transaction, id) = insertText(TextContent("Hi", alignment: .center))
        let before = try #require(transaction[id]?.frame)
        var edit = Transaction(transaction.document)
        edit.update(id) { $0.kind = .text(TextContent("Hi there, everyone", alignment: .center)) }
        edit.finalize()
        let after = try #require(edit[id]?.frame)
        #expect(abs((after.x + after.width / 2) - (before.x + before.width / 2)) < 0.5)
    }

    @Test func drawsGlyphsInTheTextColor() throws {
        let style = TextStyle(fontName: "HelveticaNeue-Bold", fontSize: 40, color: Color(hex: "#FF0000")!)
        let (transaction, id) = insertText(TextContent("IIII", style: style))
        let frame = try #require(transaction[id]?.frame)
        let bitmap = try Bitmap(width: 200, height: 100)
        CanvasRenderer().draw(page: transaction.document.pages[0], of: transaction.document, in: bitmap.context)
        var red = 0
        for x in Int(frame.x)..<Int(frame.x + frame.width) {
            for y in Int(frame.y)..<Int(frame.y + frame.height) where (bitmap.color(x: x, y: y)?.red ?? 0) > 200 {
                red += 1
            }
        }
        #expect(red > 50)
        // Nothing is drawn above the frame (the text is not upside down or shifted).
        #expect((0..<200).allSatisfy { bitmap.color(x: $0, y: 5)?.alpha == 0 })
    }

    @Test func runsMergeWhenNormalized() {
        let bold = TextStyle(fontName: "HelveticaNeue-Bold")
        let content = TextContent(runs: [
            TextRun(text: "a", style: TextStyle()), TextRun(text: "b", style: TextStyle()),
            TextRun(text: "", style: bold), TextRun(text: "c", style: bold),
        ])
        #expect(content.normalized().runs == [TextRun(text: "ab", style: TextStyle()), TextRun(text: "c", style: bold)])
    }

    @Test func textRoundTripsThroughTheFile() throws {
        let (transaction, _) = insertText(TextContent(runs: [
            TextRun(text: "Bold ", style: TextStyle(fontName: "HelveticaNeue-Bold", fontSize: 24)),
            TextRun(text: "regular", style: TextStyle(letterSpacing: 1.5, lineHeight: 32)),
        ], alignment: .center, sizing: .autoHeight), frame: Rect(x: 0, y: 0, width: 200, height: 10))
        let data = try DocumentArchive.encode(transaction.document)
        #expect(try DocumentArchive.decode(data) == transaction.document)
    }
}
