import CoreGraphics
import Foundation
import Testing
import ZIPFoundation
@testable import SkicaCore
@testable import SkicaRender

@Suite struct SketchImportTests {
    private static func color(_ red: Double, _ green: Double, _ blue: Double) -> [String: Any] {
        ["_class": "color", "red": red, "green": green, "blue": blue, "alpha": 1]
    }

    private static func style(fill: [String: Any]? = nil, opacity: Double = 1) -> [String: Any] {
        var style: [String: Any] = ["_class": "style", "contextSettings": ["opacity": opacity, "blendMode": 0]]
        if let fill { style["fills"] = [["_class": "fill", "isEnabled": true, "fillType": 0, "color": fill]] }
        return style
    }

    private static func frame(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> [String: Any] {
        ["_class": "rect", "x": x, "y": y, "width": width, "height": height]
    }

    private static func text(_ id: String, _ string: String) -> [String: Any] {
        let font = { (size: Double) -> [String: Any] in
            ["MSAttributedStringFontAttribute": ["attributes": ["name": "Helvetica", "size": size]],
             "MSAttributedStringColorAttribute": color(0, 0, 0), "paragraphStyle": ["alignment": 2]]
        }
        return ["_class": "text", "do_objectID": id, "name": "Label", "frame": frame(0, 10, 100, 20), "textBehaviour": 1,
                "style": style(), "attributedString": ["string": string, "attributes": [
                    ["location": 0, "length": 2, "attributes": font(14)],
                    ["location": 2, "length": (string as NSString).length - 2, "attributes": font(20)],
                ]]]
    }

    /// A Sketch file with a button symbol, an artboard with an instance (text overridden), a
    /// shape group cut by a subtraction and a red rectangle pinned to the right.
    static func sampleFile() throws -> Data {
        let master: [String: Any] = [
            "_class": "symbolMaster", "do_objectID": "MASTER", "symbolID": "SYM", "name": "Button",
            "frame": frame(0, 0, 100, 40), "hasBackgroundColor": true, "backgroundColor": color(0, 0, 1),
            "layers": [text("LABEL", "Héllo")],
        ]
        let ring: [String: Any] = [
            "_class": "shapeGroup", "do_objectID": "RING", "name": "Ring", "frame": frame(200, 20, 100, 100), "windingRule": 0,
            "style": style(fill: color(0, 1, 0)),
            "layers": [
                ["_class": "oval", "do_objectID": "OUTER", "frame": frame(0, 0, 100, 100), "booleanOperation": -1],
                ["_class": "oval", "do_objectID": "INNER", "frame": frame(25, 25, 50, 50), "booleanOperation": 1],
            ],
        ]
        let artboard: [String: Any] = [
            "_class": "artboard", "do_objectID": "BOARD", "name": "Screen", "frame": frame(0, 0, 400, 300),
            "hasBackgroundColor": true, "backgroundColor": color(1, 1, 1),
            "layers": [
                ["_class": "rectangle", "do_objectID": "RED", "name": "Red", "frame": frame(10, 200, 50, 50), "fixedRadius": 8,
                 "resizingConstraint": 62, "rotation": 90, "style": style(fill: color(1, 0, 0), opacity: 0.5),
                 "exportOptions": ["exportFormats": [["fileFormat": "png", "scale": 2, "name": "@2x"]]]],
                ["_class": "symbolInstance", "do_objectID": "INSTANCE", "name": "Button", "symbolID": "SYM", "frame": frame(10, 10, 160, 40),
                 "overrideValues": [["overrideName": "LABEL_stringValue", "value": "Go"]]],
                ring,
            ],
        ]
        let pages: [[String: Any]] = [
            ["_class": "page", "do_objectID": "P1", "name": "Design", "layers": [artboard]],
            ["_class": "page", "do_objectID": "P2", "name": "Symbols", "layers": [master]],
        ]
        let document: [String: Any] = [
            "_class": "document", "pages": pages.map { ["_class": "MSJSONFileReference", "_ref": "pages/\($0["do_objectID"]!)"] },
            "sharedSwatches": ["objects": [["name": "Brand", "value": color(0, 0, 1)]]],
            "layerStyles": ["objects": [["do_objectID": "STYLE", "name": "Card", "value": style(fill: color(1, 1, 0))]]],
        ]
        let archive = try Archive(accessMode: .create)
        func add(_ path: String, _ object: Any) throws {
            let data = try JSONSerialization.data(withJSONObject: object)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), provider: { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            })
        }
        try add("document.json", document)
        for page in pages { try add("pages/\(page["do_objectID"]!).json", page) }
        return try #require(archive.data)
    }

    @Test func importsPagesLayersAndAssets() throws {
        let document = try SketchImporter.document(from: Self.sampleFile())
        try document.validate()
        #expect(document.pages.map(\.name) == ["Design", "Symbols"])
        #expect(document.assets.swatches.map(\.name) == ["Brand"])
        #expect(document.assets.sharedStyles.map(\.name) == ["Card"])

        let red = try #require(document.layers[LayerID("RED")])
        #expect(red.kind == .rectangle(cornerRadius: 8))
        #expect(red.opacity == 0.5)
        #expect(red.rotation == -90)
        #expect(red.constraints == Constraints(horizontal: .end, vertical: .scale))  // 62: pinned right
        #expect(red.exports == [ExportPreset(size: .scale(2), suffix: "@2x", format: .png)])

        let label = try #require(document.layers[LayerID("LABEL")]?.textContent)
        #expect(label.string == "Héllo")
        #expect(label.runs.map(\.style.fontSize) == [14, 20])
        #expect(label.alignment == .center && label.sizing == .autoHeight)

        let instance = try #require(document.layers[LayerID("INSTANCE")]?.symbolInstance)
        #expect(instance.overrides[LayerID("LABEL")]?.text == "Go")
        #expect(document.master(of: instance.symbolID) == LayerID("MASTER"))

        let ring = try #require(document.layers[LayerID("RING")])
        #expect(ring.vectorPath?.subpaths.count == 2)
    }

    @Test func importedFileRendersLikeSketch() throws {
        let document = try SketchImporter.document(from: Self.sampleFile())
        let bitmap = try Bitmap(width: 400, height: 300)
        CanvasRenderer().draw(page: document.pages[0], of: document, in: bitmap.context)
        #expect(bitmap.color(x: 250, y: 30) == Color(hex: "#00FF00"))   // the ring
        #expect(bitmap.color(x: 250, y: 70) == .white)                   // its hole
        #expect(bitmap.color(x: 165, y: 15) == Color(hex: "#0000FF"))   // the stretched instance's background
    }

    @Test func notASketchFileFailsWithAMessage() {
        #expect(throws: ImportError.self) { try SketchImporter.document(from: Data("hello".utf8)) }
    }
}
