import AppKit
import SkicaCore

/// Cropping one image: its frame is the crop, the whole image stays where it is.
struct CropEditState {
    enum Drag {
        /// Moving an edge or corner of the crop; rectangles are in the parent's coordinates as
        /// they were when the drag started.
        case edge(SelectionHandle, frame: CGRect, image: CGRect, start: CGPoint)
        /// Sliding the image under the crop.
        case image(frame: CGRect, image: CGRect, start: CGPoint)
    }

    let layerID: LayerID
    var drag: Drag?
}

extension CanvasView {
    /// Starts cropping an image. Rotated images are cropped after rotating them back.
    func beginCropping(_ id: LayerID) {
        guard let layer = editor.document.layers[id], layer.imageHash != nil else { return NSSound.beep() }
        guard layer.rotation == 0 else {
            state.message = "Set the rotation to 0 to crop this image."
            return NSSound.beep()
        }
        endTextEditing()
        endPathEditing()
        editor.select([id])
        cropEdit = CropEditState(layerID: id)
    }

    func endCropping() {
        guard cropEdit != nil else { return }
        if editor.isLiveEditing { editor.endLiveEdit("Crop") }
        cropEdit = nil
    }

    /// The crop and the whole image on the page, for the overlay.
    func cropRects(_ crop: CropEditState) -> (frame: CGRect, image: CGRect)? {
        guard let layer = editor.document.layers[crop.layerID] else { return nil }
        let space = editor.document.parentSpace(of: crop.layerID)
        return (layer.frame.cgRect.applying(space), layer.imageRectInParent.applying(space))
    }

    /// Returns false when the click is away from the image, which ends cropping.
    func cropMouseDown(at point: CGPoint) -> Bool {
        guard var crop = cropEdit, let layer = editor.document.layers[crop.layerID], let rects = cropRects(crop) else {
            cropEdit = nil
            return false
        }
        let start = parentPoint(viewport.toCanvas(point), of: crop.layerID)
        if let handle = SelectionHandle.handle(at: point, box: viewport.toView(rects.frame)) {
            crop.drag = .edge(handle, frame: layer.frame.cgRect, image: layer.imageRectInParent, start: start)
        } else if rects.image.union(rects.frame).contains(viewport.toCanvas(point)) {
            crop.drag = .image(frame: layer.frame.cgRect, image: layer.imageRectInParent, start: start)
        } else {
            endCropping()
            return false
        }
        cropEdit = crop
        editor.beginLiveEdit()
        return true
    }

    func cropMouseDragged(to point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard let crop = cropEdit, let drag = crop.drag else { return }
        let current = parentPoint(viewport.toCanvas(point), of: crop.layerID)
        switch drag {
        case .edge(let handle, let frame, let image, let start):
            let delta = CGVector(dx: (current.x - start.x).rounded(), dy: (current.y - start.y).rounded())
            let box = SelectionHandle.resizedBox(frame, handle: handle, by: delta, keepAspect: modifiers.contains(.shift), fromCenter: modifiers.contains(.option))
            editor.updateLiveEdit { $0.setCrop(crop.layerID, frame: box.standardized, imageRect: image) }
        case .image(let frame, let image, let start):
            let delta = CGVector(dx: (current.x - start.x).rounded(), dy: (current.y - start.y).rounded())
            editor.updateLiveEdit { transaction in
                transaction.setCrop(crop.layerID, frame: frame, imageRect: image)
                transaction.moveCroppedImage(crop.layerID, by: delta)
            }
        }
    }

    func cropMouseUp() {
        cropEdit?.drag = nil
        editor.endLiveEdit("Crop")
    }

    /// Keys while cropping; returns false for keys that are not about the crop.
    func handleCropKey(_ chord: KeyChord) -> Bool {
        guard let crop = cropEdit else { return false }
        switch (chord.key, chord.modifiers) {
        case ("esc", []), ("enter", []):
            endCropping()
        case ("left", let modifiers), ("right", let modifiers), ("up", let modifiers), ("down", let modifiers):
            guard modifiers.isSubset(of: [.shift]) else { return false }
            let step: CGFloat = modifiers.contains(.shift) ? 10 : 1
            let direction: CGVector = ["left": CGVector(dx: -1, dy: 0), "right": CGVector(dx: 1, dy: 0),
                                       "up": CGVector(dx: 0, dy: -1), "down": CGVector(dx: 0, dy: 1)][chord.key]!
            editor.perform("Move Image", coalescingKey: "crop-\(crop.layerID)") { transaction in
                transaction.moveCroppedImage(crop.layerID, by: CGVector(dx: direction.dx * step, dy: direction.dy * step))
            }
        default:
            return false
        }
        return true
    }

    /// Resize arrows over the crop's handles, a hand over the image.
    func cropCursor(_ crop: CropEditState) -> NSCursor? {
        if case .image = crop.drag { return .closedHand }
        if case .edge(let handle, _, _, _) = crop.drag { return handle.cursor }
        guard let mouse = lastMouse, let rects = cropRects(crop) else { return nil }
        if let handle = SelectionHandle.handle(at: mouse, box: viewport.toView(rects.frame)) { return handle.cursor }
        return rects.image.union(rects.frame).contains(viewport.toCanvas(mouse)) ? .openHand : nil
    }

    private func parentPoint(_ page: CGPoint, of id: LayerID) -> CGPoint {
        page.applying(editor.document.parentSpace(of: id).inverted())
    }
}
