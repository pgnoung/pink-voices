import AppKit

@main struct EditingMenuCheck {
    static func main() {
        let menu = EditingMenu.makeEditMenu()
        let pairs = menu.items.compactMap { item -> String? in
            guard let action = item.action else { return nil }
            return item.keyEquivalent + ":" + NSStringFromSelector(action)
        }
        precondition(pairs.contains("v:paste:"))
        precondition(pairs.contains("c:copy:"))
        precondition(pairs.contains("x:cut:"))
        precondition(pairs.contains("a:selectAll:"))
        precondition(pairs.contains("z:undo:"))
        print("EditingMenuCheck passed")
    }
}
