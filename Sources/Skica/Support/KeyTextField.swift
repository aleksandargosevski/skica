import AppKit
import SwiftUI

/// An AppKit text field for SwiftUI that reports the keys a keyboard-first UI needs:
/// ↑/↓ (with shift), ↩, ⇥ and focus changes. Escape is handled by the keyboard router.
struct KeyTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder = ""
    var font: NSFont = .systemFont(ofSize: 12)
    var alignment: NSTextAlignment = .left
    var isBordered = true
    var focusOnAppear = false
    var onSubmit: () -> Void = {}
    /// +1 for ↑, -1 for ↓; the flag is true with shift. Returns true when handled.
    var onStep: ((Int, Bool) -> Bool)?
    var onEndEditing: () -> Void = {}
    /// Called before ⇥ / ⇧⇥ move the focus on, e.g. to commit the value.
    var onTab: (() -> Void)?
    var onFocusChange: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusReportingTextField()
        field.onFocus = { [weak coordinator = context.coordinator] in coordinator?.parent.onFocusChange(true) }
        field.delegate = context.coordinator
        field.isBordered = isBordered
        field.bezelStyle = .roundedBezel
        field.drawsBackground = isBordered
        field.focusRingType = isBordered ? .default : .none
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if focusOnAppear {
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.font = font
        field.alignment = alignment
        field.placeholderString = placeholder
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// Reports focus as soon as the field is clicked or tabbed into, not only on the first keystroke.
    final class FocusReportingTextField: NSTextField {
        var onFocus: () -> Void = {}

        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            if became { onFocus() }
            return became
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: KeyTextField

        init(parent: KeyTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onFocusChange(false)
            parent.onEndEditing()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.text = textView.string
                parent.onSubmit()
                return true
            case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveUpAndModifySelection(_:)):
                parent.text = textView.string
                return parent.onStep?(1, shift) ?? false
            case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveDownAndModifySelection(_:)):
                parent.text = textView.string
                return parent.onStep?(-1, shift) ?? false
            case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
                parent.text = textView.string
                parent.onTab?()
                return false
            default:
                return false
            }
        }
    }
}
