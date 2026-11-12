import CoreGraphics
import Foundation

/// Common screen and paper sizes for artboards.
public struct ArtboardPreset: Equatable, Sendable {
    public let name: String
    public let width: Double
    public let height: Double

    public init(_ name: String, _ width: Double, _ height: Double) {
        self.name = name
        self.width = width
        self.height = height
    }

    public static let all: [ArtboardPreset] = [
        ArtboardPreset("iPhone 16", 393, 852),
        ArtboardPreset("iPhone 16 Pro Max", 440, 956),
        ArtboardPreset("iPhone SE", 375, 667),
        ArtboardPreset("Android", 360, 800),
        ArtboardPreset("iPad", 820, 1180),
        ArtboardPreset("iPad Pro 13", 1032, 1376),
        ArtboardPreset("Apple Watch", 198, 242),
        ArtboardPreset("MacBook Air", 1280, 832),
        ArtboardPreset("MacBook Pro 14", 1512, 982),
        ArtboardPreset("Desktop", 1440, 1024),
        ArtboardPreset("Desktop HD", 1920, 1080),
        ArtboardPreset("A4", 595, 842),
        ArtboardPreset("Letter", 612, 792),
        ArtboardPreset("Instagram Post", 1080, 1080),
        ArtboardPreset("Instagram Story", 1080, 1920),
        ArtboardPreset("X Post", 1200, 675),
        ArtboardPreset("YouTube Thumbnail", 1280, 720),
        ArtboardPreset("App Icon", 1024, 1024),
    ]

    /// The preset whose name best matches `query` (fuzzy, e.g. "ipm" for iPhone 16 Pro Max).
    public static func matching(_ query: String) -> ArtboardPreset? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let exact = all.first(where: { $0.name.lowercased() == trimmed.lowercased() }) { return exact }
        return all
            .compactMap { preset in FuzzyMatch.score(trimmed, in: preset.name).map { (preset, $0) } }
            .max { $0.1 < $1.1 }?.0
    }
}
