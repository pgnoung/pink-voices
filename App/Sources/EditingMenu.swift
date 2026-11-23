import AppKit

/// Accessory apps do not receive an application menu automatically.
/// Installing the standard responder-chain edit commands lets native text fields
/// handle Command-V, Command-C, Command-X, Command-A, Undo, and Redo.
enum EditingMenu {
    static func install() {
        guard NSApp.mainMenu == nil else { return }

        let main = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "Quit \(Brand.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        main.addItem(applicationItem)

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = makeEditMenu()
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    static func makeEditMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        add("Undo", Selector(("undo:")), "z", to: menu)
        add("Redo", Selector(("redo:")), "Z", to: menu)
        menu.addItem(.separator())
        add("Cut", #selector(NSText.cut(_:)), "x", to: menu)
        add("Copy", #selector(NSText.copy(_:)), "c", to: menu)
        add("Paste", #selector(NSText.paste(_:)), "v", to: menu)
        add("Select All", #selector(NSText.selectAll(_:)), "a", to: menu)
        return menu
    }

    private static func add(_ title: String, _ action: Selector, _ key: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = nil
        menu.addItem(item)
    }
}
