import Foundation

public enum CommandCategory: String, CaseIterable, Sendable {
    case tools = "Tools"
    case edit = "Edit"
    case arrange = "Arrange"
    case selection = "Selection"
    case pages = "Pages"
    case export = "Export"
    case text = "Text"
    case vector = "Vector"
    case symbols = "Symbols & Styles"
    case view = "View"
    case app = "App"
}

/// Every action that can be triggered from the keyboard, a menu or the command palette.
public enum CommandID: String, CaseIterable, Codable, Sendable {
    // Tools
    case toolSelect, toolRectangle, toolOval, toolLine, toolPolygon, toolStar, toolPen, toolText, toolArtboard, insertImage
    // Edit
    case editGeometry, delete, duplicate, selectAll, rename, toggleHidden, toggleLocked
    // Arrange
    case bringForward, sendBackward, bringToFront, sendToBack, group, ungroup, addStack, removeStack
    case alignLeft, alignHorizontalCenter, alignRight, alignTop, alignVerticalCenter, alignBottom
    case distributeHorizontally, distributeVertically
    // Selection
    case selectNext, selectPrevious, enterSelection, escape
    // Text
    case toggleBold, toggleItalic, toggleUnderline, chooseFont
    // Export
    case exportSelection, exportMarked, exportPagePDF, copyAsPNG, copyAsSVG
    // Vector
    case editPoints, convertToPaths, outlineStroke, booleanUnion, booleanSubtract, booleanIntersect, booleanDifference, toggleMask
    // Symbols and styles
    case createSymbol, insertSymbol, swapSymbol, goToMaster, detachSymbol, resetOverrides
    case createSharedStyle, applySharedStyle, updateSharedStyle, resetToSharedStyle, detachSharedStyle
    case applyColor, addColorToPalette
    // Pages
    case newPage, deletePage, renamePage, nextPage, previousPage, goToPage, moveToPage
    // View
    case zoomIn, zoomOut, zoomActualSize, zoomToFit, zoomToSelection, toggleLayers, toggleInspector, toggleZen
    // App
    case focusLayers, focusInspector, commandPalette, selectionActions, showShortcuts, commandLine, repeatCommand, hintSelect, hintAdd

    public var title: String {
        switch self {
        case .toolSelect: "Select Tool"
        case .toolRectangle: "Rectangle"
        case .toolOval: "Oval"
        case .toolLine: "Line"
        case .toolPolygon: "Polygon"
        case .toolStar: "Star"
        case .toolPen: "Pen"
        case .toolText: "Text"
        case .insertImage: "Image…"
        case .toolArtboard: "Artboard"
        case .editGeometry: "Edit Size and Position…"
        case .delete: "Delete"
        case .duplicate: "Duplicate"
        case .selectAll: "Select All"
        case .rename: "Rename"
        case .toggleHidden: "Show/Hide"
        case .toggleLocked: "Lock/Unlock"
        case .bringForward: "Bring Forward"
        case .sendBackward: "Send Backward"
        case .bringToFront: "Bring to Front"
        case .sendToBack: "Send to Back"
        case .group: "Group"
        case .ungroup: "Ungroup"
        case .alignLeft: "Align Left"
        case .alignHorizontalCenter: "Align Horizontal Centers"
        case .alignRight: "Align Right"
        case .alignTop: "Align Top"
        case .alignVerticalCenter: "Align Vertical Centers"
        case .alignBottom: "Align Bottom"
        case .distributeHorizontally: "Distribute Horizontally"
        case .distributeVertically: "Distribute Vertically"
        case .addStack: "Add Stack"
        case .removeStack: "Remove Stack"
        case .selectNext: "Select Next Layer"
        case .selectPrevious: "Select Previous Layer"
        case .enterSelection: "Select Inside / Edit Size"
        case .escape: "Back / Select Parent"
        case .toggleBold: "Bold"
        case .toggleItalic: "Italic"
        case .toggleUnderline: "Underline"
        case .chooseFont: "Font…"
        case .exportSelection: "Export Selection…"
        case .exportMarked: "Export All Marked Layers…"
        case .exportPagePDF: "Export Page as PDF…"
        case .copyAsPNG: "Copy as PNG"
        case .copyAsSVG: "Copy as SVG"
        case .editPoints: "Edit Points"
        case .convertToPaths: "Convert to Paths"
        case .outlineStroke: "Outline Stroke"
        case .booleanUnion: "Union"
        case .booleanSubtract: "Subtract"
        case .booleanIntersect: "Intersect"
        case .booleanDifference: "Difference"
        case .toggleMask: "Mask"
        case .createSymbol: "Create Symbol…"
        case .insertSymbol: "Insert Symbol…"
        case .swapSymbol: "Swap Symbol…"
        case .goToMaster: "Go to Symbol Master"
        case .detachSymbol: "Detach from Symbol"
        case .resetOverrides: "Reset Overrides"
        case .createSharedStyle: "Create Shared Style…"
        case .applySharedStyle: "Apply Shared Style…"
        case .updateSharedStyle: "Update Shared Style from Layer"
        case .resetToSharedStyle: "Reset to Shared Style"
        case .detachSharedStyle: "Detach from Shared Style"
        case .applyColor: "Apply Color from Palette…"
        case .addColorToPalette: "Add Color to Palette"
        case .newPage: "New Page"
        case .deletePage: "Delete Page"
        case .renamePage: "Rename Page"
        case .nextPage: "Next Page"
        case .previousPage: "Previous Page"
        case .goToPage: "Go to Page…"
        case .moveToPage: "Move Selection to Page…"
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        case .zoomActualSize: "Actual Size"
        case .zoomToFit: "Zoom to Fit"
        case .zoomToSelection: "Zoom to Selection"
        case .toggleLayers: "Show/Hide Layers"
        case .toggleInspector: "Show/Hide Inspector"
        case .toggleZen: "Canvas Only"
        case .focusLayers: "Go to Layers"
        case .focusInspector: "Go to Inspector"
        case .commandPalette: "Command Palette"
        case .selectionActions: "Actions for Selection"
        case .showShortcuts: "Keyboard Shortcuts"
        case .commandLine: "Command Line"
        case .repeatCommand: "Repeat Last Command"
        case .hintSelect: "Select by Label"
        case .hintAdd: "Add to Selection by Label"
        }
    }

    public var category: CommandCategory {
        switch self {
        case .toolSelect, .toolRectangle, .toolOval, .toolLine, .toolPolygon, .toolStar, .toolPen, .toolText, .toolArtboard, .insertImage: .tools
        case .editPoints, .convertToPaths, .outlineStroke, .booleanUnion, .booleanSubtract, .booleanIntersect, .booleanDifference, .toggleMask: .vector
        case .editGeometry, .delete, .duplicate, .selectAll, .rename, .toggleHidden, .toggleLocked: .edit
        case .bringForward, .sendBackward, .bringToFront, .sendToBack, .group, .ungroup, .addStack, .removeStack,
             .alignLeft, .alignHorizontalCenter, .alignRight, .alignTop, .alignVerticalCenter, .alignBottom,
             .distributeHorizontally, .distributeVertically: .arrange
        case .selectNext, .selectPrevious, .enterSelection, .escape: .selection
        case .toggleBold, .toggleItalic, .toggleUnderline, .chooseFont: .text
        case .exportSelection, .exportMarked, .exportPagePDF, .copyAsPNG, .copyAsSVG: .export
        case .createSymbol, .insertSymbol, .swapSymbol, .goToMaster, .detachSymbol, .resetOverrides,
             .createSharedStyle, .applySharedStyle, .updateSharedStyle, .resetToSharedStyle, .detachSharedStyle,
             .applyColor, .addColorToPalette: .symbols
        case .newPage, .deletePage, .renamePage, .nextPage, .previousPage, .goToPage, .moveToPage: .pages
        case .zoomIn, .zoomOut, .zoomActualSize, .zoomToFit, .zoomToSelection, .toggleLayers, .toggleInspector, .toggleZen: .view
        case .focusLayers, .focusInspector, .commandPalette, .selectionActions, .showShortcuts, .commandLine, .repeatCommand: .app
        case .hintSelect, .hintAdd: .selection
        }
    }

    /// Commands that also fire while a text field has focus; the rest leave keys to the field.
    public var worksWhileTyping: Bool {
        switch self {
        case .escape, .commandPalette, .selectionActions, .zoomIn, .zoomOut, .zoomActualSize, .zoomToFit,
             .zoomToSelection, .toggleLayers, .toggleInspector, .toggleZen, .toggleBold, .toggleItalic, .toggleUnderline:
            true
        default:
            false
        }
    }

    /// Commands that act on the selected layers, offered by "Actions for Selection".
    public var needsSelection: Bool {
        switch category {
        case .edit, .arrange, .text, .vector: self != .selectAll
        case .symbols: self != .insertSymbol
        case .export: self == .exportSelection || self == .copyAsPNG || self == .copyAsSVG
        default: self == .zoomToSelection || self == .moveToPage
        }
    }
}

extension CommandID {
    /// The edge an align command lines layers up on.
    public var alignEdge: AlignEdge? {
        switch self {
        case .alignLeft: .left
        case .alignHorizontalCenter: .horizontalCenter
        case .alignRight: .right
        case .alignTop: .top
        case .alignVerticalCenter: .verticalCenter
        case .alignBottom: .bottom
        default: nil
        }
    }
}
