import AppKit
import SkicaCore

/// Editing one text layer in place: an NSTextView over the layer, scaled to the zoom, whose
/// changes go back into the document as they are typed (merged into one undo step per pause).
/// The canvas hides the layer itself meanwhile.
@MainActor
final class TextEditingSession: NSObject, NSTextViewDelegate {
    let layerID: LayerID
    private let editor: DocumentEditor
    private let host = TextHostView()
    let textView: NSTextView
    private var isWritingBack = false

    init(layerID: LayerID, editor: DocumentEditor, in canvas: NSView) {
        self.layerID = layerID
        self.editor = editor

        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 100_000, height: 100_000))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        textView = NSTextView(frame: .zero, textContainer: container)
        super.init()

        textView.delegate = self
        textView.isRichText = true
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.focusRingType = .none
        textView.usesFontPanel = false
        textView.insertionPointColor = .controlAccentColor
        host.addSubview(textView)
        canvas.addSubview(host)
        reloadFromDocument()
    }

    /// Puts the editor over the layer at the current zoom.
    func layout(viewport: Viewport) {
        guard let layer = editor.document.layers[layerID], let content = layer.textContent else { return }
        let space = editor.document.parentSpace(of: layerID)
        let pageFrame = layer.frame.cgRect.applying(space)
        let width = max(layer.frame.width, 1)
        let height = max(layer.frame.height, 1)
        host.frame = viewport.toView(pageFrame)
        host.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        // Auto-width text gets room to grow until the layer refits after the keystroke.
        let containerWidth = content.sizing == .autoWidth ? 100_000 : width
        textView.textContainer?.size = CGSize(width: containerWidth, height: 100_000)
        textView.frame = CGRect(x: 0, y: 0, width: content.sizing == .autoWidth ? width + 2_000 : width, height: max(height, 2_000))
    }

    /// Shows the layer's current text, e.g. after undo while editing.
    func reloadFromDocument() {
        guard !isWritingBack, let content = editor.document.layers[layerID]?.textContent else { return }
        let selection = textView.selectedRange()
        textView.textStorage?.setAttributedString(content.appKitString())
        textView.typingAttributes = content.leadingStyle.appKitAttributes(alignment: content.alignment)
        let length = textView.string.utf16.count
        textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
    }

    func selectAll() {
        textView.setSelectedRange(NSRange(location: 0, length: textView.string.utf16.count))
    }

    /// Puts the caret where a page point falls in the text.
    func placeCaret(at viewPoint: CGPoint) {
        let local = textView.convert(viewPoint, from: host.superview)
        let index = textView.characterIndexForInsertion(at: local)
        textView.setSelectedRange(NSRange(location: index, length: 0))
    }

    /// The range of text the inspector's text controls apply to, if any is selected.
    var selectedRange: NSRange? {
        let range = textView.selectedRange()
        return range.length > 0 ? range : nil
    }

    /// Restyles the selected characters (or what will be typed next).
    func applyStyle(_ change: (TextStyle) -> TextStyle, alignment: TextContent.Alignment) {
        guard let storage = textView.textStorage else { return }
        let fallback = editor.document.layers[layerID]?.textContent?.leadingStyle ?? TextStyle()
        if let range = selectedRange {
            storage.beginEditing()
            storage.enumerateAttributes(in: range) { attributes, subrange, _ in
                let style = change(TextStyle(appKitAttributes: attributes, fallback: fallback))
                storage.setAttributes(style.appKitAttributes(alignment: alignment), range: subrange)
            }
            storage.endEditing()
            writeBack(actionName: "Change Text Style")
        } else {
            let style = change(TextStyle(appKitAttributes: textView.typingAttributes, fallback: fallback))
            textView.typingAttributes = style.appKitAttributes(alignment: alignment)
        }
    }

    func end() {
        host.removeFromSuperview()
    }

    func textDidChange(_ notification: Notification) {
        writeBack(actionName: "Typing")
    }

    private func writeBack(actionName: String) {
        guard let storage = textView.textStorage, let current = editor.document.layers[layerID]?.textContent else { return }
        let content = TextContent.from(storage, base: current)
        guard content != current else { return }
        isWritingBack = true
        defer { isWritingBack = false }
        editor.perform(actionName, coalescingKey: "text-\(layerID)") { transaction in
            transaction.update(layerID) { $0.kind = .text(content) }
        }
    }
}

/// Scales the text view with the zoom through its bounds; does not clip, so text being typed
/// past the edge stays visible until the layer refits.
private final class TextHostView: NSView {
    override var isFlipped: Bool { true }
}
