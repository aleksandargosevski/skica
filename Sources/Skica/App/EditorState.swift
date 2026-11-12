import CoreGraphics
import Observation
import SkicaCore

/// Window state that is not part of the document: zoom, pointer, pending keys and prompts.
@Observable
final class EditorState {
    var zoom: CGFloat = 1
    /// The canvas point under the mouse, if it is over the canvas.
    var cursor: CGPoint?
    /// Keys of a sequence that is waiting for its next key, e.g. `g`.
    var pendingKeys: [KeyChord] = []
    /// A one-line input in the status line (size and position, page name, command line).
    var prompt: PromptState?
    /// A mode that replaces the tool name in the status line ("Pen", "Edit Points") and its keys.
    var mode: String?
    var modeHint: String?
    /// A short note in the status line, e.g. after exporting; cleared after a few seconds.
    var message: String?
}

struct PromptState: Equatable {
    enum Kind: Equatable {
        case geometry
        case renamePage(PageID)
        case commandLine
        case createSymbol
        case createSharedStyle
    }

    var kind: Kind
    var title: String
    var text = ""
    var placeholder = ""
    var hint = "↩ apply   esc cancel"
    var error: String?
}
