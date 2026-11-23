import AppKit

// Scoring is local. The finalizer owns any network call and reports its result
// through this controller, so UI choices never invoke legacy word suggestions.
final class WordReviewController: NSObject {
    private let defaults: UserDefaults
    private var latest: DictationSummary?
    private var resultNote = ""
    private var detailsItem: NSMenuItem?

    var onSettingsChanged: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }

    var finalReviewConfiguration: FinalReviewConfiguration {
        let mode = FinalReviewMode(rawValue: defaults.string(forKey: "finalReviewMode") ?? "") ?? .local
        guard mode == .openAI,
              let selected = defaults.string(forKey: "finalReviewModel"),
              FinalReviewCatalog.selectableModels.contains(where: { $0.rawValue == selected }) else {
            return FinalReviewConfiguration(mode: .local, models: [], keySource: .chatGPT)
        }
        let source = FinalReviewKeySource(rawValue: defaults.string(forKey: "finalReviewKeySource") ?? "") ?? .chatGPT
        return FinalReviewConfiguration(mode: .openAI, models: [selected], keySource: source, writingNote: writingNote)
    }

    /// Returns a key only for the person's explicit selected source. Company
    /// lookup is exact and happens only after the Company option was chosen.
    func finalReviewKey() -> String? {
        let configuration = finalReviewConfiguration
        guard configuration.isOnline else { return nil }
        return FinalReviewKeys.resolve(configuration.keySource)
    }

    var reviewResultNote: String { resultNote }
    var reviewSpans: [ReviewSpan] { latest?.spans ?? [] }

    func setReviewResultNote(_ note: String) {
        resultNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        refresh()
    }

    func addItems(to menu: NSMenu, displayScore: Bool = true) {
        let details = menu.addItem(withTitle: "ผลตรวจคำครั้งล่าสุด…", action: #selector(showResults), keyEquivalent: "")
        details.target = self
        if displayScore { detailsItem = details; refresh() }
        let configure = menu.addItem(withTitle: "โหมดถอดและตรวจคำ…", action: #selector(configureReview), keyEquivalent: "")
        configure.target = self
        let guidance = menu.addItem(withTitle: "คำแนะนำการถอด…", action: #selector(editGuidance), keyEquivalent: "")
        guidance.target = self
    }

    var needsReview: Bool { latest?.needsReview == true }

    private func refresh() {
        detailsItem?.title = latest.map { "ผลตรวจคำ • \($0.title)…" } ?? "ผลตรวจคำครั้งล่าสุด…"
    }

    func beginDictation() { resultNote = "" }

    // It does not perform network work, enforce a daily quota, or read legacy
    // reviewer keys. The finalizer consumes the public configuration instead.
    func finish(_ reports: [DictationAssessment?], settings: Settings, heard: String) {
        let known = settings.dictionaryEnabled ? settings.dictionaryText.components(separatedBy: .newlines).compactMap {
            (try? BrandDictionary.rows($0))?.first
        } : []
        let summary = DictationSummary(reports, taught: known, heard: heard)
        latest = summary
        refresh()
    }

    @objc func showResults() {
        let box = NSAlert()
        box.messageText = latest?.title ?? "ผลตรวจคำครั้งล่าสุด"
        if let latest {
            var lines = ["คะแนนจากกฎตรวจคำในเครื่อง คะแนนต่ำแปลว่ามีจุดให้ทบทวน ตัวเลขนี้ไม่ได้วัดโอกาสที่เสียงจะถูกเป็นเปอร์เซ็นต์"]
            if latest.incomplete { lines.append("บางช่วงมีเพียงการเทียบข้อความระหว่างพูดกับผลสุดท้าย เพราะเซิร์ฟเวอร์ส่งรายละเอียดคะแนนไม่ครบ") }
            for span in latest.spans.prefix(12) {
                let variants = (span.candidates ?? []).prefix(3).joined(separator: " / ")
                lines.append("\(span.categoryTitle) • \(span.text)\n\(span.explanation)" + (variants.isEmpty ? "" : "   ตัวเลือก \(variants)"))
            }
            if !resultNote.isEmpty { lines.append(resultNote) }
            if !latest.spans.isEmpty { lines.append("หากพบคำที่ถูก เลือก “สอนคำจากครั้งล่าสุด…” เพื่อให้แอปจำ") }
            box.informativeText = lines.joined(separator: "\n\n")
        } else { box.informativeText = "กด Option ขวาค้างแล้วพูด ผลตรวจจะขึ้นเมื่อถอดข้อความเสร็จ" }
        box.addButton(withTitle: "ปิด")
        NSApp.activate(ignoringOtherApps: true)
        box.runModal()
    }

    var writingNote: String {
        DictationGuidance.normalized(defaults.string(forKey: "dictationWritingNote") ?? "")
    }

    @objc func editGuidance() {
        let box = NSAlert()
        box.messageText = "คำแนะนำการถอด"
        box.informativeText = DictationGuidance.standard + "\n\nโหมดออนไลน์ใช้กติกานี้หลัง Local AI ถอดเสียงแล้ว คุณเพิ่มคำแนะนำการสะกดได้อีก 240 ตัวอักษร ข้อความที่เพิ่มจะส่งไปกับการตรวจออนไลน์แต่ละครั้ง"
        let field = NSTextField(string: writingNote)
        field.frame = NSRect(x: 0, y: 0, width: 390, height: 26)
        field.placeholderString = "ตัวอย่าง  คงคำลงท้าย ครับ และ ค่ะ ตามที่พูด"
        field.setAccessibilityLabel("คำแนะนำการเขียนเพิ่มเติม")
        box.accessoryView = field
        box.addButton(withTitle: "บันทึก")
        box.addButton(withTitle: "ยกเลิก")
        NSApp.activate(ignoringOtherApps: true)
        guard box.runModal() == .alertFirstButtonReturn else { return }
        guard field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).count <= DictationGuidance.limit else {
            presentWarning("คำแนะนำยาวเกินไป", "ใช้ข้อความไม่เกิน 240 ตัวอักษร คำแนะนำเดิมยังใช้ได้")
            return
        }
        let note = DictationGuidance.normalized(field.stringValue)
        guard note != writingNote else { return }
        defaults.set(note, forKey: "dictationWritingNote")
        onSettingsChanged?()
    }

    @objc func configureReview() {
        let current = finalReviewConfiguration
        let box = NSAlert()
        box.messageText = "โหมดถอดและตรวจคำ"
        box.informativeText = "Local AI ถอดเสียงในเครื่องก่อนเสมอ\n\nในเครื่องไม่ส่งข้อมูลออกจาก Mac โหมด OpenAI จะส่งเฉพาะข้อความที่ถอดแล้วทั้งช่วงและคำศัพท์ที่เกี่ยวข้อง เพื่อตรวจทานก่อนใส่ข้อความ ไม่ส่งเสียง และไม่ส่งโน้ตหรือคลัง Plaud ทั้งหมด\n\nSign in with ChatGPT ใช้โควตาแพ็กเกจ ChatGPT ของคุณ ส่วน API key จะคิดเงินตามบัญชี API นั้น"

        let mode = NSPopUpButton(frame: .zero, pullsDown: false)
        mode.addItems(withTitles: ["ในเครื่องเท่านั้น", "Local AI → OpenAI ตรวจทานก่อนใส่"])
        mode.selectItem(at: current.isOnline ? 1 : 0)
        let model = NSPopUpButton(frame: .zero, pullsDown: false)
        model.addItems(withTitles: FinalReviewCatalog.selectableModels.map { candidate in
            candidate == .gpt6Luna ? "gpt-6-luna (เลือก Legacy โดยตรง)" : candidate.displayName
        })
        if let selected = current.model, let index = FinalReviewCatalog.selectableModels.firstIndex(where: { $0.rawValue == selected }) { model.selectItem(at: index) }
        let availability = NSTextField(wrappingLabelWithString: "เลือกได้ 1 รุ่นต่อครั้ง: gpt-6.1-terra หรือ gpt-6.2-sol\nเลือก gpt-6-luna ได้เฉพาะเมื่อเลือก Legacy โดยตรง ส่วน gpt-6.1-luna ยังไม่เปิดให้บัญชีนี้ แอปจะไม่สลับรุ่นให้เอง")
        availability.maximumNumberOfLines = 3
        availability.preferredMaxLayoutWidth = 390

        let sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        sourcePopup.addItems(withTitles: FinalReviewKeySource.allCases.map(\.title))
        sourcePopup.selectItem(at: FinalReviewKeySource.allCases.firstIndex(of: current.keySource) ?? 0)
        sourcePopup.setAccessibilityLabel("วิธีเชื่อม OpenAI")
        let personalKey = NSSecureTextField()
        personalKey.placeholderString = "OpenAI API key ของฉัน (ใช้เมื่อเลือก API key เท่านั้น)"
        personalKey.setAccessibilityLabel("OpenAI API key ของฉัน")
        personalKey.widthAnchor.constraint(equalToConstant: 390).isActive = true
        let signedIn = ChatGPTAccount.current()?.label
        let keyNote = NSTextField(wrappingLabelWithString: signedIn.map { "ChatGPT ที่ล็อกอินไว้: \($0)" }
            ?? "เลือก Sign in with ChatGPT แล้วกดบันทึก แอปจะเปิดเบราว์เซอร์ให้ล็อกอิน ChatGPT ส่วนคีย์บริษัทใช้ได้เมื่อระบบบริษัทตั้งค่าไว้บน Mac นี้แล้วเท่านั้น")
        keyNote.maximumNumberOfLines = 3
        keyNote.preferredMaxLayoutWidth = 390
        let controls = NSStackView(views: [mode, model, availability, sourcePopup, personalKey, keyNote])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 8
        controls.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        box.accessoryView = controls
        box.addButton(withTitle: "บันทึกการตั้งค่า")
        box.addButton(withTitle: "ยกเลิก")
        NSApp.activate(ignoringOtherApps: true)
        guard box.runModal() == .alertFirstButtonReturn else { return }

        guard mode.indexOfSelectedItem == 1 else {
            defaults.set(FinalReviewMode.local.rawValue, forKey: "finalReviewMode")
            resultNote = "ใช้ Local AI ในเครื่องเท่านั้น"
            onSettingsChanged?()
            return
        }
        guard FinalReviewCatalog.selectableModels.indices.contains(model.indexOfSelectedItem) else {
            presentWarning("ยังเปิดตรวจทานออนไลน์ไม่ได้", "เลือกรุ่น OpenAI ที่ยืนยันว่าใช้ได้ก่อน")
            return
        }
        let source = FinalReviewKeySource.allCases.indices.contains(sourcePopup.indexOfSelectedItem)
            ? FinalReviewKeySource.allCases[sourcePopup.indexOfSelectedItem] : .chatGPT
        if source == .personalKey, !personalKey.stringValue.isEmpty, !FinalReviewKeys.save(personalKey.stringValue) {
            presentWarning("บันทึกคีย์ไม่ได้", "กรอก OpenAI API key ที่ถูกต้อง หรือเลือกคีย์บริษัทที่ตั้งค่าไว้แล้ว")
            return
        }
        if source == .personalKey, FinalReviewKeys.key() == nil {
            presentWarning("ยังไม่มีคีย์สำหรับตรวจทาน", "กรอก OpenAI API key ของคุณก่อน หรือเลือก Sign in with ChatGPT")
            return
        }
        let selected = FinalReviewCatalog.selectableModels[model.indexOfSelectedItem]
        if source == .chatGPT, ChatGPTAccount.current() == nil { beginChatGPTSignIn() }
        defaults.set(FinalReviewMode.openAI.rawValue, forKey: "finalReviewMode")
        defaults.set(selected.rawValue, forKey: "finalReviewModel")
        defaults.set(source.rawValue, forKey: "finalReviewKeySource")
        resultNote = "จะตรวจทานด้วย \(selected.displayName) ก่อนใส่ข้อความ"
        onSettingsChanged?()
    }

    /// Opens the browser for "Sign in with ChatGPT"; the result arrives asynchronously.
    func beginChatGPTSignIn(completion: ((Result<ChatGPTConnection, ChatGPTAccountError>) -> Void)? = nil) {
        resultNote = "กำลังรอการล็อกอิน ChatGPT ในเบราว์เซอร์"
        Task { [weak self] in
            let result: Result<ChatGPTConnection, ChatGPTAccountError>
            do { result = .success(try await ChatGPTAccount.shared.signIn()) }
            catch { result = .failure(error as? ChatGPTAccountError ?? .network) }
            await MainActor.run {
                guard let self else { return }
                switch result {
                case .success(let connection):
                    self.defaults.set(FinalReviewKeySource.chatGPT.rawValue, forKey: "finalReviewKeySource")
                    self.resultNote = "เชื่อม ChatGPT แล้ว: \(connection.label)"
                case .failure(let error):
                    self.resultNote = error.message
                    if error != .cancelled { self.presentWarning("ล็อกอิน ChatGPT ไม่สำเร็จ", error.message) }
                }
                self.onSettingsChanged?()
                completion?(result)
            }
        }
    }

    func signOutChatGPT() {
        Task { [weak self] in
            await ChatGPTAccount.shared.signOut()
            await MainActor.run { self?.resultNote = "ออกจากระบบ ChatGPT แล้ว"; self?.onSettingsChanged?() }
        }
    }

    private func presentWarning(_ title: String, _ message: String) {
        let warning = NSAlert()
        warning.messageText = title
        warning.informativeText = message
        warning.addButton(withTitle: "ตกลง")
        warning.runModal()
    }
}
