import CoreGraphics
import Foundation

public struct Layer: Codable, Equatable, Sendable, Identifiable {
    public var id: LayerID
    public var name: String
    public var kind: LayerKind
    /// Relative to the parent's origin; absolute for top-level layers.
    public var frame: Rect
    /// Degrees, clockwise, around the frame's center.
    public var rotation: Double
    public var opacity: Double
    public var isVisible: Bool
    public var isLocked: Bool
    /// Clips the layers above it in the same parent to its shape.
    public var isMask: Bool
    /// The shared style this layer follows, if any.
    public var sharedStyleID: SharedStyleID?
    public var style: Style
    public var parent: LayerID?
    /// Bottom to top.
    public var children: [LayerID]
    /// Files this layer is exported as; empty for layers that are not marked for export.
    public var exports: [ExportPreset]
    /// How the layer follows its artboard or symbol when that is resized.
    public var constraints: Constraints
    /// For containers: lays the children out in a row or column.
    public var stack: StackLayout?
    /// For images: where the whole bitmap is drawn, relative to the frame's origin. The frame
    /// shows the part inside it (a crop); nil draws the bitmap filling the frame.
    public var imageCrop: Rect?

    public init(
        id: LayerID = .make(),
        name: String,
        kind: LayerKind,
        frame: Rect,
        rotation: Double = 0,
        opacity: Double = 1,
        isVisible: Bool = true,
        isLocked: Bool = false,
        isMask: Bool = false,
        style: Style = Style(),
        parent: LayerID? = nil,
        children: [LayerID] = [],
        exports: [ExportPreset] = []
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.frame = frame
        self.rotation = rotation
        self.opacity = opacity
        self.isVisible = isVisible
        self.isLocked = isLocked
        self.isMask = isMask
        self.sharedStyleID = nil
        self.style = style
        self.parent = parent
        self.children = children
        self.exports = exports
        self.constraints = Constraints()
        self.stack = nil
        self.imageCrop = nil
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, frame, rotation, opacity, isVisible, isLocked, isMask, sharedStyleID, style, parent, children, exports, constraints, stack, imageCrop
    }

    /// Fields added after format 1 (exports) decode with defaults, so older files keep opening.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(LayerID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(LayerKind.self, forKey: .kind)
        frame = try container.decode(Rect.self, forKey: .frame)
        rotation = try container.decode(CodingKeys.rotation, default: 0)
        opacity = try container.decode(CodingKeys.opacity, default: 1)
        isVisible = try container.decode(CodingKeys.isVisible, default: true)
        isLocked = try container.decode(CodingKeys.isLocked, default: false)
        isMask = try container.decode(CodingKeys.isMask, default: false)
        sharedStyleID = try container.decodeIfPresent(SharedStyleID.self, forKey: .sharedStyleID)
        style = try container.decode(CodingKeys.style, default: Style())
        parent = try container.decodeIfPresent(LayerID.self, forKey: .parent)
        children = try container.decode(CodingKeys.children, default: [])
        exports = try container.decode(CodingKeys.exports, default: [])
        constraints = try container.decode(CodingKeys.constraints, default: Constraints())
        stack = try container.decodeIfPresent(StackLayout.self, forKey: .stack)
        imageCrop = try container.decodeIfPresent(Rect.self, forKey: .imageCrop)
    }

    public var isContainer: Bool {
        switch kind {
        case .artboard, .symbolMaster, .group: true
        case .rectangle, .oval, .line, .polygon, .star, .path, .text, .image, .symbolInstance: false
        }
    }

    /// Artboards and symbol masters: top-level frames that clip their contents.
    public var isArtboard: Bool {
        switch kind {
        case .artboard, .symbolMaster: true
        default: false
        }
    }

    public var symbolID: SymbolID? {
        if case .symbolMaster(let id) = kind { return id }
        return nil
    }

    public var symbolInstance: SymbolInstance? {
        if case .symbolInstance(let instance) = kind { return instance }
        return nil
    }

    public var imageHash: String? {
        if case .image(let hash) = kind { return hash }
        return nil
    }

    public var vectorPath: VectorPath? {
        if case .path(let path) = kind { return path }
        return nil
    }

    public var textContent: TextContent? {
        if case .text(let content) = kind { return content }
        return nil
    }
}

public enum LayerKind: Codable, Equatable, Sendable {
    case artboard
    /// The original of a symbol; it works like an artboard, and instances show its contents.
    case symbolMaster(SymbolID)
    case symbolInstance(SymbolInstance)
    case group
    case rectangle(cornerRadius: Double)
    case oval
    /// A straight line between two corners of the frame, in unit coordinates (0 or 1).
    case line(from: UnitPoint, to: UnitPoint)
    case polygon(sides: Int)
    /// `innerRadius` is the inner points' distance from the center as a fraction of the outer one.
    case star(points: Int, innerRadius: Double)
    case path(VectorPath)
    case text(TextContent)
    /// A bitmap stretched to the frame; the bytes live in `Document.images` under `hash`.
    case image(hash: String)

    public var title: String {
        switch self {
        case .artboard: "Artboard"
        case .symbolMaster: "Symbol"
        case .symbolInstance: "Symbol Instance"
        case .group: "Group"
        case .rectangle: "Rectangle"
        case .oval: "Oval"
        case .line: "Line"
        case .polygon: "Polygon"
        case .star: "Star"
        case .path: "Path"
        case .text: "Text"
        case .image: "Image"
        }
    }
}

public struct UnitPoint: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let topLeft = UnitPoint(x: 0, y: 0)
    public static let bottomRight = UnitPoint(x: 1, y: 1)
}

public struct Rect: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
