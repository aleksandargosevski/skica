import CoreGraphics
import Foundation

extension Transaction {
    /// Layout that follows an edit: text frames fit their text, then groups fit their children.
    public mutating func finalize() {
        fitText()
        fitPaths()
        fitImageCrops()
        layoutResizedContainers()
        layoutStacks()
        fitGroups()
    }

    /// Sizes changed text layers to their text. Resizing a text layer by hand switches how it
    /// sizes, as in Sketch: a new width wraps the text (auto height), a new height fixes both.
    public mutating func fitText() {
        for id in touched {
            guard let layer = document.layers[id], var content = layer.textContent else { continue }
            if let before = original.layers[id], before.textContent != nil {
                if abs(before.frame.width - layer.frame.width) > 0.001, content.sizing == .autoWidth {
                    content.sizing = .autoHeight
                }
                if abs(before.frame.height - layer.frame.height) > 0.001, content.sizing == .autoHeight,
                   before.textContent == layer.textContent {
                    content.sizing = .fixed
                }
            }

            var frame = layer.frame
            switch content.sizing {
            case .autoWidth:
                let size = TextLayout.size(of: content, width: nil)
                // Centered and right-aligned text grows from its center or right edge.
                switch content.alignment {
                case .center: frame.x += (frame.width - size.width) / 2
                case .right: frame.x += frame.width - size.width
                case .left, .justified: break
                }
                frame.width = size.width
                frame.height = size.height
            case .autoHeight:
                frame.height = TextLayout.size(of: content, width: frame.width).height
            case .fixed:
                break
            }
            let fitted = frame
            update(id) { layer in
                layer.kind = .text(content)
                layer.frame = fitted
            }
        }
    }
}
