import CoreGraphics
import CoreImage

/// Draws into an offscreen bitmap at the destination's device resolution, blurs it with Core
/// Image and composites it back.
///
/// Used for shadows and layer blur instead of `CGContext.setShadow`, whose offsets live in a
/// "base space" that differs between bitmap and layer-backed contexts (flipped, in points or
/// pixels), which made on-screen shadows land in the wrong place.
enum Offscreen {
    /// `userBounds` (in the context's current coordinates) must contain everything `draw` paints,
    /// including the blur's spread.
    static func drawBlurred(in context: CGContext, userBounds: CGRect, radius: CGFloat, alpha: CGFloat = 1,
                            blendMode: CGBlendMode = .normal, draw: (CGContext) -> Void) {
        let ctm = context.ctm
        // Low-resolution destinations (PDF pages are 72 dpi) still get effects at 2× detail.
        let detail = max(1, 2 / scale(of: ctm))
        let deviceRadius = radius * scale(of: ctm) * detail
        let deviceBounds = userBounds.applying(ctm).integral
        let pixelWidth = Int((deviceBounds.width * detail).rounded(.up))
        let pixelHeight = Int((deviceBounds.height * detail).rounded(.up))
        guard pixelWidth >= 1, pixelHeight >= 1, pixelWidth * pixelHeight < 64_000_000,
              let offscreen = CGContext(
                  data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return }
        offscreen.scaleBy(x: detail, y: detail)
        offscreen.concatenate(ctm.concatenating(CGAffineTransform(translationX: -deviceBounds.minX, y: -deviceBounds.minY)))
        draw(offscreen)

        guard var image = offscreen.makeImage() else { return }
        if deviceRadius > 0.1 {
            let input = CIImage(cgImage: image)
            // Design tools give blur as a radius; Gaussian sigma is about half of it.
            let blurred = input.applyingGaussianBlur(sigma: deviceRadius / 2).cropped(to: input.extent)
            guard let output = ciContext.createCGImage(blurred, from: input.extent) else { return }
            image = output
        }

        context.saveGState()
        context.concatenate(ctm.inverted())
        context.setAlpha(alpha)
        context.setBlendMode(blendMode)
        context.draw(image, in: deviceBounds)
        context.restoreGState()
    }

    static func scale(of transform: CGAffineTransform) -> CGFloat {
        max(hypot(transform.a, transform.b), 0.0001)
    }

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])
}
