import CoreGraphics
import Foundation

/// The whole drawing: ordered pages, and every layer of every page in one flat table.
///
/// Containers (artboards, groups) list their children bottom to top; child frames are
/// relative to the parent's origin.
public struct Document: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var pages: [Page]
    public var layers: [LayerID: Layer]
    /// Image files by the SHA-256 of their bytes; stored as `images/<hash>` in the archive,
    /// not in `document.json`.
    public var images: [String: Data] = [:]
    public var assets = DocumentAssets()

    enum CodingKeys: String, CodingKey {
        case version, pages, layers, assets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        pages = try container.decode([Page].self, forKey: .pages)
        layers = try container.decode([LayerID: Layer].self, forKey: .layers)
        assets = try container.decode(CodingKeys.assets, default: DocumentAssets())
    }

    public init(pages: [Page] = [Page(name: "Page 1")], layers: [LayerID: Layer] = [:]) {
        self.version = Self.currentVersion
        self.pages = pages
        self.layers = layers
    }

    /// Hashes of images some layer shows.
    public var referencedImages: Set<String> {
        Set(layers.values.compactMap(\.imageHash))
    }

    public func page(_ id: PageID) -> Page? {
        pages.first { $0.id == id }
    }

    public func topLevelLayers(of page: Page) -> [Layer] {
        page.layers.compactMap { layers[$0] }
    }

    public func children(of layer: Layer) -> [Layer] {
        layer.children.compactMap { layers[$0] }
    }

    /// Union of all top-level frames on the page, or nil for an empty page.
    public func contentBounds(of page: Page) -> CGRect? {
        topLevelLayers(of: page)
            .map(\.frame.cgRect)
            .reduce(nil) { union, rect in union?.union(rect) ?? rect }
    }

    /// Checks that every referenced layer exists exactly once and parents match their children.
    public func validate() throws {
        guard !pages.isEmpty else { throw DocumentError.corrupt("The document has no pages.") }
        var seen = Set<LayerID>()

        func visit(_ id: LayerID, parent: LayerID?) throws {
            guard let layer = layers[id] else { throw DocumentError.corrupt("Layer \(id) is referenced but missing.") }
            guard seen.insert(id).inserted else { throw DocumentError.corrupt("Layer \(id) appears more than once.") }
            guard layer.parent == parent else { throw DocumentError.corrupt("Layer \(id) has the wrong parent.") }
            for child in layer.children { try visit(child, parent: id) }
        }

        for page in pages {
            for id in page.layers { try visit(id, parent: nil) }
        }
        if seen.count != layers.count {
            throw DocumentError.corrupt("\(layers.count - seen.count) layers are not on any page.")
        }
    }
}

public struct Page: Codable, Equatable, Sendable, Identifiable {
    public var id: PageID
    public var name: String
    /// Top-level layers, bottom to top.
    public var layers: [LayerID]

    public init(id: PageID = .make(), name: String, layers: [LayerID] = []) {
        self.id = id
        self.name = name
        self.layers = layers
    }
}

public enum DocumentError: LocalizedError, Equatable {
    case notASkicaFile
    case missingDocument
    case newerVersion(Int)
    case corrupt(String)
    case couldNotWrite(String)

    public var errorDescription: String? {
        switch self {
        case .notASkicaFile:
            "The file is not a Skica document."
        case .missingDocument:
            "The file is damaged: document.json is missing."
        case .newerVersion(let version):
            "The document was made with a newer version of Skica (format \(version)). Update Skica to open it."
        case .corrupt(let detail):
            "The file is damaged. \(detail)"
        case .couldNotWrite(let detail):
            "The document could not be saved. \(detail)"
        }
    }
}
