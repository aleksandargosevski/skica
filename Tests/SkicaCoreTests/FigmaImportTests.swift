import CoreGraphics
import Foundation
import Testing
@testable import SkicaCore
@testable import SkicaRender

@Suite struct FigmaImportTests {
    private static func box(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> [String: Any] {
        ["absoluteBoundingBox": ["x": x, "y": y, "width": width, "height": height], "size": ["x": width, "y": height],
         "relativeTransform": [[1, 0, x], [0, 1, y]]]
    }

    private static func solid(_ r: Double, _ g: Double, _ b: Double) -> [[String: Any]] {
        [["type": "SOLID", "color": ["r": r, "g": g, "b": b, "a": 1]]]
    }

    private static func node(_ id: String, _ type: String, _ name: String, _ frame: [String: Any], _ extra: [String: Any] = [:]) -> [String: Any] {
        var node: [String: Any] = ["id": id, "type": type, "name": name]
        node.merge(frame) { _, new in new }
        node.merge(extra) { _, new in new }
        return node
    }

    private static func label(_ id: String, _ text: String, _ frame: [String: Any]) -> [String: Any] {
        node(id, "TEXT", "Label", frame, [
            "characters": text, "fills": solid(1, 1, 1), "textAutoResize": "WIDTH_AND_HEIGHT",
            "style": ["fontFamily": "Helvetica", "fontWeight": 400, "fontSize": 14, "textAlignHorizontal": "CENTER"],
            "characterStyleOverrides": [0, 0, 1], "styleOverrideTable": ["1": ["fontWeight": 700, "fills": solid(1, 0, 0)]],
        ])
    }

    static func file() throws -> Data {
        let button = node("1:10", "COMPONENT", "Primary", box(500, 0, 100, 40), [
            "fills": solid(0, 0, 1),
            "children": [label("1:11", "Buy", box(530, 10, 40, 20))],
        ])
        let set = node("1:9", "COMPONENT_SET", "Button", box(480, -20, 200, 100), ["children": [button]])
        let instance = node("2:5", "INSTANCE", "Buy Button", box(20, 200, 200, 40), [
            "componentId": "1:10",
            "children": [label("I2:5;1:11", "Pay", box(100, 210, 40, 20))],
        ])
        let card = node("2:6", "FRAME", "Card", box(20, 20, 120, 120), [
            "fills": solid(1, 1, 0), "clipsContent": true, "cornerRadius": 8,
            "children": [node("2:7", "ELLIPSE", "Dot", box(100, 100, 80, 80), ["fills": solid(0, 1, 0)])],
        ])
        let arrow = node("2:8", "VECTOR", "Arrow", box(300, 20, 40, 40), [
            "fills": solid(0, 0, 0), "fillGeometry": [["path": "M0 0L40 20L0 40Z", "windingRule": "NONZERO"]],
            "constraints": ["horizontal": "RIGHT", "vertical": "TOP_BOTTOM"],
            "effects": [["type": "DROP_SHADOW", "visible": true, "radius": 4, "offset": ["x": 0, "y": 2], "color": ["r": 0, "g": 0, "b": 0, "a": 0.25]]],
        ])
        let row = node("2:9", "FRAME", "Row", box(20, 300, 100, 20), [
            "layoutMode": "HORIZONTAL", "itemSpacing": 4, "paddingLeft": 2,
            "children": [node("2:10", "RECTANGLE", "A", box(22, 300, 20, 20), ["fills": solid(0, 0, 0)])],
        ])
        let screen = node("2:1", "FRAME", "Screen", box(0, 0, 400, 400), [
            "fills": solid(1, 1, 1),
            "exportSettings": [["format": "PNG", "suffix": "@2x", "constraint": ["type": "SCALE", "value": 2]]],
            "children": [card, arrow, instance, row],
        ])
        let file: [String: Any] = ["name": "Test", "document": ["id": "0:0", "type": "DOCUMENT", "children": [
            ["id": "0:1", "type": "CANVAS", "name": "Design", "children": [screen, set]],
        ]]]
        return try JSONSerialization.data(withJSONObject: file)
    }

    @Test func fileKeysComeFromLinks() {
        #expect(FigmaImporter.fileKey(from: "https://www.figma.com/design/AbC123xyz/My-File?node-id=1-2") == "AbC123xyz")
        #expect(FigmaImporter.fileKey(from: "https://figma.com/file/KEY42/Name") == "KEY42")
        #expect(FigmaImporter.fileKey(from: "KEY42") == "KEY42")
        #expect(FigmaImporter.fileKey(from: "https://example.com/design/KEY") == nil)
    }

    @Test func importsFramesComponentsAndInstances() throws {
        let document = try FigmaImporter.document(fromFile: Self.file())
        #expect(document.pages.map(\.name) == ["Design"])
        let page = document.pages[0]
        let names = page.layers.compactMap { document.layers[$0]?.name }
        #expect(names == ["Screen", "Button/Primary"])

        let master = try #require(document.layers[LayerID("1:10")])
        #expect(master.symbolID == SymbolID("1:10"))
        #expect(master.frame == Rect(x: 500, y: 0, width: 100, height: 40))
        let label = try #require(document.layers[LayerID("1:11")]?.textContent)
        #expect(label.string == "Buy")
        #expect(label.runs.count == 2)
        #expect(label.runs[1].style.color == Color(hex: "#FF0000"))

        let instance = try #require(document.layers[LayerID("2:5")]?.symbolInstance)
        #expect(instance.symbolID == SymbolID("1:10"))
        #expect(instance.overrides[LayerID("1:11")]?.text == "Pay")

        let arrow = try #require(document.layers[LayerID("2:8")])
        #expect(arrow.vectorPath?.subpaths.first?.points.count == 3)
        #expect(arrow.constraints == Constraints(horizontal: .end, vertical: .both))
        #expect(arrow.style.shadows.first?.blur == 4)
        #expect(document.layers[LayerID("2:1")]?.exports == [ExportPreset(size: .scale(2), suffix: "@2x", format: .png)])

        let row = try #require(document.layers[LayerID("2:9")])
        #expect(row.stack?.spacing == 4 && row.stack?.padding.left == 2)
    }

    @Test func nestedFramesClipAndRender() throws {
        let document = try FigmaImporter.document(fromFile: Self.file())
        let card = try #require(document.layers[LayerID("2:6")])
        let background = try #require(card.children.first.flatMap { document.layers[$0] })
        #expect(background.isMask && background.kind == .rectangle(cornerRadius: 8))

        let bitmap = try Bitmap(width: 400, height: 400)
        CanvasRenderer().draw(page: document.pages[0], of: document, in: bitmap.context)
        #expect(bitmap.color(x: 30, y: 30) == Color(hex: "#FFFF00"))
        #expect(bitmap.color(x: 130, y: 130) == Color(hex: "#00FF00"))  // the dot inside the card
        #expect(bitmap.color(x: 170, y: 170) == .white)                  // clipped outside it
        #expect(bitmap.color(x: 210, y: 205) == Color(hex: "#0000FF"))   // the instance's background
    }

    @Test func notAFigmaFileFails() {
        #expect(throws: ImportError.self) { try FigmaImporter.document(fromFile: Data("{}".utf8)) }
    }
}
