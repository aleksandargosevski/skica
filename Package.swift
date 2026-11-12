// swift-tools-version: 6.0
import PackageDescription

let languageMode: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Skica",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "skica-cli", targets: ["SkicaCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
        .package(url: "https://github.com/SDWebImage/libwebp-Xcode.git", from: "1.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Skica",
            dependencies: ["SkicaCore", "SkicaRender"],
            path: "Sources/Skica",
            swiftSettings: languageMode
        ),
        .executableTarget(
            name: "SkicaCLI",
            dependencies: ["SkicaCore", "SkicaRender"],
            path: "Sources/SkicaCLI",
            swiftSettings: languageMode
        ),
        // Quick Look thumbnails and previews; scripts/build.sh packs it into two .appex bundles.
        .executableTarget(
            name: "SkicaQuickLook",
            dependencies: ["SkicaCore", "SkicaRender"],
            path: "Sources/SkicaQuickLook",
            swiftSettings: languageMode,
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
        .target(
            name: "SkicaCore",
            dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation")],
            path: "Sources/SkicaCore",
            swiftSettings: languageMode
        ),
        .target(
            name: "SkicaRender",
            dependencies: ["SkicaCore", .product(name: "libwebp", package: "libwebp-Xcode")],
            path: "Sources/SkicaRender",
            swiftSettings: languageMode
        ),
        .testTarget(
            name: "SkicaCoreTests",
            dependencies: ["SkicaCore", "SkicaRender", .product(name: "ZIPFoundation", package: "ZIPFoundation")],
            path: "Tests/SkicaCoreTests",
            swiftSettings: languageMode
        ),
    ]
)
