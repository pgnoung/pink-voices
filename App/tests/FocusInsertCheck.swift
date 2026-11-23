import Foundation
import AppKit
import ApplicationServices

@main struct FocusInsertCheck {
    static func main() {
        precondition(SafeInserter.isSafeNativeText("วันนี้ทดสอบ Pink voices molto"))
        precondition(!SafeInserter.isSafeNativeText(""))
        precondition(!SafeInserter.isSafeNativeText("ข้อความ\nกดส่ง"))
        precondition(!SafeInserter.isSafeNativeText(String(repeating: "ก", count: 1_201)))
        precondition(SafeInserter.requiresTargetedPaste("ข้อความ\nหลายบรรทัด"))
        precondition(SafeInserter.requiresTargetedPaste(String(repeating: "ก", count: 1_201)))
        precondition(!SafeInserter.requiresTargetedPaste("ข้อความปกติ"))
        precondition(SafeInserter.isSafePasteText("ข้อความ\r\nหลายบรรทัด"))
        precondition(!SafeInserter.isSafePasteText("ข้อความ\u{1B}ไม่ปลอดภัย"))
        precondition(!SafeInserter.isSafePasteText("ข้อความ\u{0}ไม่ปลอดภัย"))
        precondition(SafeInserter.isDefinitiveAXRejection(.attributeUnsupported))
        precondition(SafeInserter.isDefinitiveAXRejection(.notImplemented))
        precondition(!SafeInserter.isDefinitiveAXRejection(.cannotComplete))
        let board = NSPasteboard.withUniqueName()
        board.clearContents()
        precondition(board.setString("ก่อนหน้า", forType: .string))
        precondition(board.setData(Data([1, 2, 3]), forType: .rtf))
        let beforeFirstStage = board.changeCount
        guard let firstStage = SafeInserter.stagePasteboard("ข้อความใหม่", on: board) else { fatalError("first pasteboard stage failed") }
        precondition(board.changeCount > beforeFirstStage)
        precondition(board.string(forType: .string) == "ข้อความใหม่")
        precondition(board.data(forType: .rtf) == nil)
        precondition(SafeInserter.owns(firstStage, on: board))
        board.clearContents()
        precondition(board.setString("ข้อความอื่น", forType: .string))
        precondition(!SafeInserter.owns(firstStage, on: board))
        let beforeSecondStage = board.changeCount
        guard let secondStage = SafeInserter.stagePasteboard("ข้อความครั้งที่สอง", on: board) else { fatalError("second pasteboard stage failed") }
        precondition(board.changeCount > beforeSecondStage)
        precondition(board.string(forType: .string) == "ข้อความครั้งที่สอง")
        precondition(SafeInserter.owns(secondStage, on: board))
        precondition(!FocusSnapshot.isEligibleEditor(role: "AXStaticText", editable: nil, hasSelectedRange: true, selectedTextIsSettable: false, inWebArea: true))
        precondition(!FocusSnapshot.isEligibleEditor(role: kAXTextAreaRole, editable: false, hasSelectedRange: true, selectedTextIsSettable: true, inWebArea: true))
        precondition(FocusSnapshot.isEligibleEditor(role: kAXTextAreaRole, editable: nil, hasSelectedRange: true, selectedTextIsSettable: true, inWebArea: true))
        print("FocusInsertCheck passed")
    }
}
