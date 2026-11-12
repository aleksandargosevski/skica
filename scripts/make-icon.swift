#!/usr/bin/env swift
// Renders Resources/AppIcon.icns from Resources/AppIconSource.png.
// The source has a transparent background around its rounded square; the square is found by its
// opaque pixels and scaled onto the macOS icon grid (824pt body, 100pt margin on 1024).
// Usage: swift scripts/make-icon.swift [source.png] [output.icns]
import AppKit

let arguments = CommandLine.arguments.dropFirst()
let sourcePath = arguments.first ?? "Resources/AppIconSource.png"
let outputPath = arguments.dropFirst().first ?? "Resources/AppIcon.icns"

main()

func main() {
    do {
        guard let source = NSImage(contentsOfFile: sourcePath),
              let cgSource = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw failure("Could not read \(sourcePath)")
        }
        let body = try bodyRect(in: cgSource)
        guard let cropped = cgSource.cropping(to: body) else { throw failure("Could not crop the icon body") }

        let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Skica.iconset")
        try? FileManager.default.removeItem(at: iconset)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            try writePNG(cropped, pixels: points, to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
            try writePNG(cropped, pixels: points * 2, to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
        }
        try runIconutil(iconset: iconset, output: outputPath)
        print("Wrote \(outputPath)")
    } catch {
        FileHandle.standardError.write("Error: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}

/// The bounding box of the clearly opaque pixels, i.e. the rounded square without its soft edge.
func bodyRect(in image: CGImage) throws -> CGRect {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw failure("Could not read pixels") }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var minX = width, minY = height, maxX = 0, maxY = 0
    for row in 0..<height {
        for x in 0..<width where pixels[(row * width + x) * 4 + 3] > 128 {
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, row)
            maxY = max(maxY, row)
        }
    }
    guard maxX > minX, maxY > minY else { throw failure("\(sourcePath) has no opaque pixels") }
    // The bitmap's rows run bottom to top; cropping counts from the top.
    return CGRect(x: minX, y: height - 1 - maxY, width: maxX - minX + 1, height: maxY - minY + 1)
}

/// Draws the body centered in an 824/1024 square of the icon, keeping its proportions.
func writePNG(_ body: CGImage, pixels: Int, to url: URL) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw failure("Could not create a bitmap")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let canvas = CGFloat(pixels)
    let side = canvas * 824 / 1024
    let scale = side / CGFloat(max(body.width, body.height))
    let size = CGSize(width: CGFloat(body.width) * scale, height: CGFloat(body.height) * scale)
    let rect = CGRect(x: (canvas - size.width) / 2, y: (canvas - size.height) / 2, width: size.width, height: size.height)
    context.cgContext.draw(body, in: rect)
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw failure("Could not encode PNG") }
    try png.write(to: url)
}

func runIconutil(iconset: URL, output: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconset.path, "-o", output]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw failure("iconutil failed with status \(process.terminationStatus)") }
}

func failure(_ message: String) -> NSError {
    NSError(domain: "make-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}
