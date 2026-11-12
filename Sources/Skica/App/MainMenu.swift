import AppKit
import SkicaCore

/// The menu bar, built in code. Shortcut labels come from the keymap; the keyboard router
/// handles the keys themselves before AppKit sees them.
@MainActor
enum MainMenu {
    static func build(keymap: Keymap) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(submenu(appMenu()))
        menu.addItem(submenu(fileMenu()))
        menu.addItem(submenu(editMenu(keymap: keymap)))
        menu.addItem(submenu(commandMenu("Text", [.toggleBold, .toggleItalic, .toggleUnderline, .chooseFont], keymap: keymap)))
        menu.addItem(submenu(commandMenu("Insert", [.toolSelect, .toolRectangle, .toolOval, .toolLine, .toolPolygon, .toolStar, .toolPen, .toolText, .toolArtboard, .insertImage], keymap: keymap)))
        menu.addItem(submenu(commandMenu("Vector", [.editPoints, .convertToPaths, .outlineStroke, .booleanUnion, .booleanSubtract, .booleanIntersect, .booleanDifference, .toggleMask], keymap: keymap)))
        menu.addItem(submenu(commandMenu("Symbols", [
            .createSymbol, .insertSymbol, .swapSymbol, .goToMaster, .detachSymbol, .resetOverrides,
            .createSharedStyle, .applySharedStyle, .updateSharedStyle, .resetToSharedStyle, .detachSharedStyle,
            .applyColor, .addColorToPalette,
        ], keymap: keymap)))
        menu.addItem(submenu(commandMenu("Arrange", [.group, .ungroup, .addStack, .removeStack, .bringForward, .sendBackward, .bringToFront, .sendToBack,
             .alignLeft, .alignHorizontalCenter, .alignRight, .alignTop, .alignVerticalCenter, .alignBottom,
             .distributeHorizontally, .distributeVertically], keymap: keymap)))
        menu.addItem(submenu(commandMenu("Export", [.exportSelection, .exportMarked, .exportPagePDF, .copyAsPNG, .copyAsSVG], keymap: keymap)))
        menu.addItem(submenu(commandMenu("Page", [.newPage, .renamePage, .deletePage, .nextPage, .previousPage, .goToPage, .moveToPage], keymap: keymap)))
        menu.addItem(submenu(viewMenu(keymap: keymap)))
        let window = windowMenu()
        menu.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = helpMenu()
        menu.addItem(submenu(help))
        NSApp.helpMenu = help
        return menu
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Skica")
        menu.addItem(item("About Skica", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Install Command Line Tool…", #selector(AppDelegate.installCommandLineTool(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Hide Skica", #selector(NSApplication.hide(_:)), key: "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit Skica", #selector(NSApplication.terminate(_:)), key: "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("New", #selector(NSDocumentController.newDocument(_:)), key: "n"))
        menu.addItem(item("Open…", #selector(NSDocumentController.openDocument(_:)), key: "o"))
        // AppKit fills a submenu that contains the "Clear Menu" item with recent documents.
        let recent = NSMenu(title: "Open Recent")
        recent.addItem(item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:))))
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recentItem.submenu = recent
        menu.addItem(recentItem)
        menu.addItem(item("Import from Figma…", #selector(AppDelegate.importFromFigma(_:)), key: "o", modifiers: [.command, .control]))
        menu.addItem(.separator())
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), key: "w"))
        menu.addItem(item("Save", #selector(NSDocument.save(_:)), key: "s"))
        menu.addItem(item("Duplicate", #selector(NSDocument.duplicate(_:)), key: "s", modifiers: [.command, .shift]))
        menu.addItem(item("Rename…", #selector(NSDocument.rename(_:))))
        menu.addItem(item("Move To…", #selector(NSDocument.move(_:))))
        menu.addItem(item("Revert to Saved", #selector(NSDocument.revertToSaved(_:))))
        return menu
    }

    /// Text-editing actions use the standard selectors, so text fields keep ⌘A, ⌘C and friends.
    private static func editMenu(keymap: Keymap) -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), key: "z"))
        menu.addItem(item("Redo", Selector(("redo:")), key: "z", modifiers: [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), key: "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), key: "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), key: "v"))
        menu.addItem(commandItem(.duplicate, keymap: keymap))
        menu.addItem(item("Delete", #selector(NSText.delete(_:))))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), key: "a"))
        menu.addItem(.separator())
        for command in [CommandID.editGeometry, .rename, .toggleHidden, .toggleLocked] {
            menu.addItem(commandItem(command, keymap: keymap))
        }
        return menu
    }

    private static func viewMenu(keymap: Keymap) -> NSMenu {
        let menu = commandMenu("View", [.zoomIn, .zoomOut, .zoomActualSize, .zoomToFit, .zoomToSelection], keymap: keymap)
        menu.addItem(.separator())
        for command in [CommandID.toggleLayers, .toggleInspector, .toggleZen, .focusLayers, .focusInspector] {
            menu.addItem(commandItem(command, keymap: keymap))
        }
        menu.addItem(.separator())
        for command in [CommandID.commandPalette, .selectionActions, .showShortcuts] {
            menu.addItem(commandItem(command, keymap: keymap))
        }
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), key: "f", modifiers: [.command, .control]))
        return menu
    }

    private static func commandMenu(_ title: String, _ commands: [CommandID], keymap: Keymap) -> NSMenu {
        let menu = NSMenu(title: title)
        for command in commands { menu.addItem(commandItem(command, keymap: keymap)) }
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    private static func helpMenu() -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(item("New Sample Document", #selector(AppDelegate.newSampleDocument(_:))))
        menu.addItem(item("New Stress Test Document (5,000 Layers)", #selector(AppDelegate.newStressDocument(_:))))
        return menu
    }

    /// A menu item that runs a command on the active document window. Only ⌘/⌃ shortcuts are
    /// shown as key equivalents: plain keys (tools, delete) would be taken from text fields.
    private static func commandItem(_ command: CommandID, keymap: Keymap) -> NSMenuItem {
        let menuItem = item(command.title, #selector(DocumentWindowController.performCommand(_:)))
        menuItem.representedObject = command.rawValue
        let chord = keymap.sequences(for: command)
            .first { $0.chords.count == 1 && !$0.chords[0].modifiers.isDisjoint(with: [.command, .control]) }?
            .chords.first
        if let chord {
            menuItem.keyEquivalent = chord.menuKeyEquivalent
            menuItem.keyEquivalentModifierMask = chord.menuModifiers
        } else if let sequence = keymap.primary(for: command) {
            menuItem.title += "    \(sequence.displayText)"
        }
        return menuItem
    }

    private static func item(_ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { menuItem.keyEquivalentModifierMask = modifiers }
        return menuItem
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let menuItem = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        menuItem.submenu = menu
        return menuItem
    }
}

private extension KeyChord {
    var menuKeyEquivalent: String {
        switch key {
        case "enter": "\r"
        case "esc": "\u{1b}"
        case "tab": "\t"
        case "space": " "
        case "backspace": "\u{8}"
        case "delete": "\u{7f}"
        case "up": String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case "down": String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case "left": String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case "right": String(UnicodeScalar(NSRightArrowFunctionKey)!)
        default: key
        }
    }

    var menuModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return flags
    }
}
