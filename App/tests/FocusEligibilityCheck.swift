import Foundation
import ApplicationServices

@main struct FocusEligibilityCheck {
    static func main() {
        // Standard and search fields may expose AXEditable without a selection range.
        precondition(FocusSnapshot.isEligibleEditor(
            role: kAXTextFieldRole, editable: true, hasSelectedRange: false,
            selectedTextIsSettable: false, inWebArea: false
        ))
        precondition(FocusSnapshot.isEligibleEditor(
            role: kAXComboBoxRole, editable: true, hasSelectedRange: false,
            selectedTextIsSettable: false, inWebArea: false
        ))
        precondition(FocusSnapshot.isEligibleEditor(
            role: kAXTextFieldRole, editable: nil, hasSelectedRange: true,
            selectedTextIsSettable: false, inWebArea: false
        ))
        precondition(!FocusSnapshot.isEligibleEditor(
            role: kAXTextAreaRole, editable: nil, hasSelectedRange: true,
            selectedTextIsSettable: false, inWebArea: false
        ))
        precondition(FocusSnapshot.isEligibleEditor(
            role: kAXTextAreaRole, editable: nil, hasSelectedRange: false,
            selectedTextIsSettable: false, valueIsSettable: true, inWebArea: false
        ))

        // Custom native and web editors require positive editability, never a range alone.
        precondition(FocusSnapshot.isEligibleEditor(
            role: "AXCustomEditor", editable: true, hasSelectedRange: false,
            selectedTextIsSettable: false, inWebArea: false
        ))
        precondition(FocusSnapshot.isEligibleEditor(
            role: "AXCustomEditor", editable: nil, hasSelectedRange: false,
            selectedTextIsSettable: true, inWebArea: true
        ))
        precondition(!FocusSnapshot.isEligibleEditor(
            role: "AXCustomEditor", editable: nil, hasSelectedRange: true,
            selectedTextIsSettable: false, inWebArea: true
        ))

        // Read-only controls and containers/documents are never insertion targets.
        precondition(!FocusSnapshot.isEligibleEditor(
            role: kAXTextAreaRole, editable: false, hasSelectedRange: true,
            selectedTextIsSettable: true, inWebArea: false
        ))
        for role in ["AXStaticText", "AXWebArea", "AXDocument", "AXWindow"] {
            precondition(!FocusSnapshot.isEligibleEditor(
                role: role, editable: true, hasSelectedRange: true,
                selectedTextIsSettable: true, inWebArea: true
            ))
        }
        print("FocusEligibilityCheck passed")
    }
}
