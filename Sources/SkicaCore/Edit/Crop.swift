import CoreGraphics
import Foundation

extension Layer {
    /// Where the whole image is drawn, relative to the frame's origin.
    public var imageRect: CGRect {
        imageCrop?.cgRect ?? CGRect(origin: .zero, size: frame.cgRect.size)
    }

    /// The image's rectangle in the parent's coordinates.
    public var imageRectInParent: CGRect {
        imageRect.offsetBy(dx: frame.x, dy: frame.y)
    }
}

extension Transaction {
    /// Cropped images resized like any layer scale their crop along, so they look stretched
    /// the same way an uncropped image does.
    mutating func fitImageCrops() {
        for id in touched {
            guard let layer = document.layers[id], let crop = layer.imageCrop, let before = original.layers[id],
                  before.imageCrop == crop, before.frame.width > 0, before.frame.height > 0,
                  before.frame.width != layer.frame.width || before.frame.height != layer.frame.height else { continue }
            let scaleX = layer.frame.width / before.frame.width
            let scaleY = layer.frame.height / before.frame.height
            update(id) { $0.imageCrop = Rect(x: crop.x * scaleX, y: crop.y * scaleY, width: crop.width * scaleX, height: crop.height * scaleY) }
        }
    }

    /// Shows the part of the image inside `frame` (parent coordinates), with the whole image at
    /// `imageRect` (also parent coordinates). The frame is kept inside the image.
    public mutating func setCrop(_ id: LayerID, frame: CGRect, imageRect: CGRect) {
        guard document.layers[id]?.imageHash != nil, imageRect.width > 0, imageRect.height > 0 else { return }
        var visible = frame.standardized.intersection(imageRect)
        if visible.isNull || visible.width < 1 || visible.height < 1 {
            visible = CGRect(x: min(max(frame.minX, imageRect.minX), imageRect.maxX - 1), y: min(max(frame.minY, imageRect.minY), imageRect.maxY - 1),
                             width: 1, height: 1)
        }
        let crop = imageRect.offsetBy(dx: -visible.minX, dy: -visible.minY)
        let isWholeImage = abs(crop.minX) < 0.01 && abs(crop.minY) < 0.01
            && abs(crop.width - visible.width) < 0.01 && abs(crop.height - visible.height) < 0.01
        update(id) { layer in
            layer.frame = Rect(visible)
            layer.imageCrop = isWholeImage ? nil : Rect(crop)
        }
    }

    /// Slides the image under its crop, keeping the crop covered by the image.
    public mutating func moveCroppedImage(_ id: LayerID, by delta: CGVector) {
        guard let layer = document.layers[id], layer.imageHash != nil else { return }
        let frame = layer.frame.cgRect
        var image = layer.imageRectInParent.offsetBy(dx: delta.dx, dy: delta.dy)
        image.origin.x = min(max(image.minX, frame.maxX - image.width), frame.minX)
        image.origin.y = min(max(image.minY, frame.maxY - image.height), frame.minY)
        setCrop(id, frame: frame, imageRect: image)
    }

    /// Shows the whole image again, where it was under the crop.
    public mutating func resetCrop(_ ids: [LayerID]) {
        for id in ids {
            guard let layer = document.layers[id], layer.imageCrop != nil else { continue }
            let image = layer.imageRectInParent
            update(id) { layer in
                layer.frame = Rect(image)
                layer.imageCrop = nil
            }
        }
    }
}
