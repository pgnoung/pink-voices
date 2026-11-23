import AppKit

/// A retained editor for explicitly saved speech corrections. It does not keep dictation history.
enum BrandDictionaryEditor {
    private static var controller: DictionaryWindowController?

    static func edit(_ settings: Settings, recentText: String = "") {
        let controller = controller ?? DictionaryWindowController()
        self.controller = controller
        controller.present(settings: settings, recentText: recentText, chooseRecentText: false)
    }

    static func teach(_ settings: Settings, recentText: String) {
        let controller = controller ?? DictionaryWindowController()
        self.controller = controller
        controller.present(settings: settings, recentText: recentText, chooseRecentText: true)
    }
}

private final class DictionaryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private var settings: Settings?
    private var rows: [BrandDictionary.Row] = []
    private var filteredRows: [BrandDictionary.Row] = []
    private var selectedAlias: String?
    private var recentText = ""
    private var hasLoadedSettings = false
    private var editingEnabled = true

    private let searchField = NSSearchField()
    private let heardField = NSTextField()
    private let spellingField = NSTextField()
    private let recentLabel = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "บันทึกคำ", target: nil, action: nil)
    private let deleteButton = NSButton(title: "ลบคำ", target: nil, action: nil)
    private let repairButton = NSButton(title: "ซ่อมข้อมูลเดิม…", target: nil, action: nil)
    private let dictionaryEnabledButton = NSButton(checkboxWithTitle: "ใช้คำที่สอนตอนพิมพ์", target: nil, action: nil)
    private var editingControls: [NSControl] = []

    init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 535),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(Brand.name) • สอนคำ"
        PinkTheme.style(window)
        window.minSize = NSSize(width: 600, height: 455)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildWindow()
    }

    required init?(coder: NSCoder) { nil }

    func present(settings: Settings, recentText: String, chooseRecentText: Bool) {
        let settingsChanged = self.settings.map { $0 !== settings } ?? true
        self.settings = settings
        self.recentText = recentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if settingsChanged || !hasLoadedSettings {
            loadRows()
            clearFields()
            hasLoadedSettings = true
        } else {
            updateRecentLabel()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if chooseRecentText { showRecentPicker() }
    }

    private func buildWindow() {
        guard let content = window?.contentView else { return }
        let headline = NSTextField(labelWithString: "สอนคำให้ \(Brand.name)")
        headline.font = .systemFont(ofSize: 22, weight: .bold)
        headline.textColor = NSColor(calibratedRed: 0.89, green: 0.25, blue: 0.52, alpha: 1)
        let explanation = NSTextField(wrappingLabelWithString: "แก้คำที่ถอดผิดเป็นคำที่ต้องการ ครั้งต่อไป \(Brand.name) จะจัดข้อความให้ก่อนใส่ในแอป")
        explanation.font = .systemFont(ofSize: 13)
        explanation.textColor = .secondaryLabelColor

        searchField.placeholderString = "ค้นหาคำที่สอนแล้ว"
        searchField.delegate = self
        searchField.setAccessibilityLabel("ค้นหาคำที่สอนแล้ว")
        recentLabel.font = .systemFont(ofSize: 12)
        recentLabel.textColor = .secondaryLabelColor
        recentLabel.maximumNumberOfLines = 2

        let heardLabel = label("คำที่ได้ยิน")
        let spellingLabel = label("คำที่ต้องการให้พิมพ์")
        heardField.placeholderString = "เช่น มอโต้"
        heardField.setAccessibilityLabel("คำที่ได้ยิน")
        spellingField.placeholderString = "เช่น molto"
        spellingField.setAccessibilityLabel("คำที่ต้องการให้พิมพ์")
        let pasteHeardButton = button("วาง", #selector(pasteHeard), "วางข้อความในช่องคำที่ได้ยิน")
        let pasteSpellingButton = button("วาง", #selector(pasteSpelling), "วางข้อความในช่องคำที่ต้องการให้พิมพ์")

        let useRecentButton = button("เลือกจากข้อความล่าสุด…", #selector(useRecentText), "เลือกคำจากข้อความล่าสุดเพื่อสอน")
        let brandOnlyButton = button("เพิ่มชื่อแบรนด์", #selector(useSpellingAsBrand), "ใช้คำที่ต้องการเป็นชื่อแบรนด์โดยไม่ต้องเพิ่มคำที่ได้ยิน")
        saveButton.target = self
        saveButton.action = #selector(saveCorrection)
        saveButton.bezelColor = NSColor(calibratedRed: 0.89, green: 0.25, blue: 0.52, alpha: 1)
        saveButton.setAccessibilityLabel("บันทึกคำสอน")
        let newButton = button("เพิ่มคำใหม่", #selector(clearFields), "เพิ่มคำสอนใหม่")
        deleteButton.target = self
        deleteButton.action = #selector(deleteCorrection)
        deleteButton.isEnabled = false
        deleteButton.setAccessibilityLabel("ลบคำที่เลือก")
        let exportButton = button("ส่งออกคำศัพท์…", #selector(exportVocabulary), "บันทึกสำเนาคำศัพท์ \(Brand.name) เป็นไฟล์ JSON")
        repairButton.target = self
        repairButton.action = #selector(repairLegacyData)
        repairButton.isHidden = true
        dictionaryEnabledButton.target = self
        dictionaryEnabledButton.action = #selector(toggleDictionaryEnabled)
        dictionaryEnabledButton.setAccessibilityLabel("เปิดหรือปิดการใช้คำที่สอนตอนพิมพ์")

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        table.headerView = NSTableHeaderView()
        table.usesAlternatingRowBackgroundColors = true
        table.delegate = self
        table.dataSource = self
        table.setAccessibilityLabel("รายการคำที่ \(Brand.name) จำไว้")
        addColumn(identifier: NSUserInterfaceItemIdentifier("heard"), title: "ได้ยินว่า", width: 230)
        addColumn(identifier: NSUserInterfaceItemIdentifier("spelling"), title: "ให้พิมพ์เป็น", width: 255)
        scroll.documentView = table

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let heardInput = inputRow(field: heardField, pasteButton: pasteHeardButton)
        let spellingInput = inputRow(field: spellingField, pasteButton: pasteSpellingButton)
        let form = NSGridView(views: [[heardLabel, spellingLabel], [heardInput, spellingInput]])
        form.xPlacement = .fill
        form.column(at: 0).width = 275
        form.column(at: 1).width = 275
        form.row(at: 0).bottomPadding = 4
        form.row(at: 1).bottomPadding = 6

        let assistActions = NSStackView(views: [useRecentButton, brandOnlyButton, exportButton, repairButton])
        assistActions.orientation = .horizontal
        assistActions.spacing = 8
        let primaryActions = NSStackView(views: [saveButton, newButton, deleteButton])
        primaryActions.orientation = .horizontal
        primaryActions.spacing = 8
        let actionRows = NSStackView(views: [dictionaryEnabledButton, assistActions, primaryActions])
        actionRows.orientation = .vertical
        actionRows.spacing = 8
        actionRows.alignment = .leading

        let header = NSStackView(views: [headline, explanation, searchField, recentLabel])
        header.orientation = .vertical
        header.spacing = 8
        header.alignment = .leading
        let root = NSStackView(views: [header, scroll, form, actionRows, statusLabel])
        root.orientation = .vertical
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        editingControls = [heardField, spellingField, pasteHeardButton, pasteSpellingButton, useRecentButton, brandOnlyButton, saveButton, newButton, deleteButton]
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 170),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 310),
            heardInput.heightAnchor.constraint(equalToConstant: 26),
            spellingInput.heightAnchor.constraint(equalToConstant: 26)
        ])
    }

    private func label(_ text: String) -> NSTextField {
        let view = NSTextField(labelWithString: text)
        view.font = .systemFont(ofSize: 12, weight: .semibold)
        return view
    }

    private func button(_ title: String, _ action: Selector, _ accessibilityLabel: String) -> NSButton {
        let view = NSButton(title: title, target: self, action: action)
        view.bezelStyle = .rounded
        view.setAccessibilityLabel(accessibilityLabel)
        return view
    }

    private func inputRow(field: NSTextField, pasteButton: NSButton) -> NSStackView {
        let row = NSStackView(views: [field, pasteButton])
        row.orientation = .horizontal
        row.spacing = 6
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pasteButton.setContentHuggingPriority(.required, for: .horizontal)
        return row
    }

    private func addColumn(identifier: NSUserInterfaceItemIdentifier, title: String, width: CGFloat) {
        let column = NSTableColumn(identifier: identifier)
        column.title = title
        column.width = width
        column.minWidth = 130
        table.addTableColumn(column)
    }

    private func loadRows() {
        guard let settings else { return }
        do {
            rows = try BrandDictionary.rows(settings.dictionaryText)
            statusLabel.stringValue = "จำคำไว้ \(rows.count) คู่"
            setEditingEnabled(true)
        } catch {
            rows = []
            setEditingEnabled(false)
            statusLabel.stringValue = "ข้อมูลคำศัพท์เดิมมีปัญหา: \(error.localizedDescription) • กดซ่อมข้อมูลเดิมก่อนแก้คำ"
        }
        dictionaryEnabledButton.state = settings.dictionaryEnabled ? .on : .off
        updateRecentLabel()
        filterRows()
    }

    private func updateRecentLabel() {
        recentLabel.stringValue = recentText.isEmpty
            ? "ยังไม่มีข้อความล่าสุดให้เลือกเป็นคำตั้งต้น"
            : "มีข้อความล่าสุด กด “เลือกจากข้อความล่าสุด…” เพื่อเลือกเฉพาะคำที่ต้องการสอน"
    }

    private func setEditingEnabled(_ enabled: Bool) {
        editingEnabled = enabled
        editingControls.forEach { $0.isEnabled = enabled }
        table.isEnabled = enabled
        repairButton.isHidden = enabled
    }

    private func filterRows() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: .caseInsensitive, locale: .current)
        filteredRows = query.isEmpty ? rows : rows.filter {
            $0.alias.folding(options: .caseInsensitive, locale: .current).contains(query)
                || $0.spelling.folding(options: .caseInsensitive, locale: .current).contains(query)
        }
        table.reloadData()
        selectedAlias = nil
        deleteButton.isEnabled = false
    }

    @objc private func useRecentText() {
        showRecentPicker()
    }

    @objc private func pasteHeard() {
        paste(into: heardField, fieldName: "คำที่ได้ยิน")
    }

    @objc private func pasteSpelling() {
        paste(into: spellingField, fieldName: "คำที่ต้องการให้พิมพ์")
    }

    private func paste(into field: NSTextField, fieldName: String) {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            statusLabel.stringValue = "Clipboard ไม่มีข้อความให้วาง"
            return
        }
        field.stringValue = text
        field.becomeFirstResponder()
        statusLabel.stringValue = "วางข้อความในช่อง\(fieldName)แล้ว"
    }

    private func showRecentPicker() {
        guard editingEnabled else { return }
        guard !recentText.isEmpty else {
            statusLabel.stringValue = "ยังไม่มีข้อความล่าสุดให้เลือก"
            return
        }
        let alert = NSAlert()
        alert.messageText = "เลือกคำที่ต้องการสอน"
        alert.informativeText = "เลือกเฉพาะคำที่ถอดผิด แล้วกดใช้คำที่เลือก"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 430, height: 130))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let textView = NSTextView(frame: scroll.contentView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 15)
        textView.string = recentText
        textView.setAccessibilityLabel("ข้อความล่าสุด เลือกคำที่ต้องการสอน")
        scroll.documentView = textView
        alert.accessoryView = scroll
        alert.addButton(withTitle: "ใช้คำที่เลือก")
        alert.addButton(withTitle: "ยกเลิก")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let selected = (textView.string as NSString).substring(with: textView.selectedRange()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty else {
            statusLabel.stringValue = "เลือกคำอย่างน้อยหนึ่งคำก่อน"
            return
        }
        table.deselectAll(nil)
        heardField.stringValue = selected
        if let existing = rows.first(where: { $0.alias.caseInsensitiveCompare(selected) == .orderedSame }) {
            selectedAlias = existing.alias
            spellingField.stringValue = existing.spelling
            saveButton.title = "อัปเดตคำ"
            deleteButton.isEnabled = true
            statusLabel.stringValue = "พบคำที่สอนไว้แล้ว แก้คำที่ต้องการแล้วกดอัปเดตคำ"
        } else {
            selectedAlias = nil
            spellingField.stringValue = ""
            saveButton.title = "บันทึกคำ"
            deleteButton.isEnabled = false
            statusLabel.stringValue = "ใส่คำที่เลือกแล้ว พิมพ์คำที่ถูกต้องด้านขวา"
        }
        spellingField.becomeFirstResponder()
    }

    @objc private func useSpellingAsBrand() {
        let brand = spellingField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brand.isEmpty else {
            statusLabel.stringValue = "พิมพ์ชื่อแบรนด์ที่ต้องการก่อน"
            spellingField.becomeFirstResponder()
            return
        }
        selectedAlias = nil
        table.deselectAll(nil)
        heardField.stringValue = brand
        saveButton.title = "บันทึกคำ"
        saveCorrection()
    }

    @objc private func clearFields() {
        selectedAlias = nil
        table.deselectAll(nil)
        heardField.stringValue = ""
        spellingField.stringValue = ""
        saveButton.title = "บันทึกคำ"
        deleteButton.isEnabled = false
        heardField.becomeFirstResponder()
    }

    @objc private func saveCorrection() {
        guard editingEnabled else { return }
        let alias = heardField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let spelling = spellingField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alias.isEmpty, !spelling.isEmpty else {
            statusLabel.stringValue = "กรอกทั้งคำที่ได้ยินและคำที่ต้องการให้พิมพ์"
            return
        }
        guard !alias.contains("="), !alias.contains(where: { $0.isNewline }),
              !spelling.contains(where: { $0.isNewline }) else {
            statusLabel.stringValue = "คำที่สอนห้ามมีเครื่องหมาย = หรือขึ้นบรรทัดใหม่"
            return
        }
        if selectedAlias == nil,
           rows.contains(where: { $0.alias.caseInsensitiveCompare(alias) == .orderedSame }) {
            statusLabel.stringValue = "มีคำ “\(alias)” อยู่แล้ว เลือกรายการนั้นเพื่ออัปเดต"
            return
        }
        if let selectedAlias,
           rows.contains(where: {
               $0.alias.caseInsensitiveCompare(alias) == .orderedSame
                   && $0.alias.caseInsensitiveCompare(selectedAlias) != .orderedSame
           }) {
            statusLabel.stringValue = "คำที่ได้ยินนี้ซ้ำกับรายการอื่น เลือกคำให้ไม่ซ้ำก่อนบันทึก"
            return
        }
        var next = rows.filter { $0.alias.caseInsensitiveCompare(selectedAlias ?? alias) != .orderedSame }
        next.append(BrandDictionary.Row(alias: alias, spelling: spelling))
        save(rows: next, success: "บันทึกแล้ว • \(alias) → \(spelling)")
    }

    private func save(rows next: [BrandDictionary.Row], success: String) {
        let encoded = next.map { "\($0.alias)=\($0.spelling)" }.joined(separator: "\n")
        do {
            _ = try BrandDictionary.rows(encoded)
            settings?.dictionaryText = encoded
            rows = next.sorted { $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending }
            statusLabel.stringValue = success
            filterRows()
            clearFields()
        } catch {
            statusLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func deleteCorrection() {
        guard let selectedAlias else { return }
        let alert = NSAlert()
        alert.messageText = "ลบคำที่สอนแล้ว?"
        alert.informativeText = "\(Brand.name) จะไม่แทนคำ “\(selectedAlias)” อีกต่อไป"
        alert.addButton(withTitle: "ลบคำ")
        alert.addButton(withTitle: "ยกเลิก")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        save(rows: rows.filter { $0.alias.caseInsensitiveCompare(selectedAlias) != .orderedSame }, success: "ลบคำแล้ว")
    }

    @objc private func toggleDictionaryEnabled() {
        settings?.dictionaryEnabled = dictionaryEnabledButton.state == .on
        statusLabel.stringValue = dictionaryEnabledButton.state == .on
            ? "\(Brand.name) จะใช้คำที่สอนกับข้อความใหม่"
            : "\(Brand.name) จะหยุดใช้คำที่สอนชั่วคราว"
    }

    @objc private func repairLegacyData() {
        guard let settings else { return }
        let alert = NSAlert()
        alert.messageText = "ซ่อมข้อมูลคำศัพท์เดิม"
        alert.informativeText = "แก้ข้อมูลให้แต่ละบรรทัดเป็น คำที่ได้ยิน=คำที่ต้องการ แล้วกดบันทึก ข้อมูลเดิมจะไม่เปลี่ยนจนกว่าจะผ่านการตรวจ"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 450, height: 180))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let textView = NSTextView(frame: scroll.contentView.bounds)
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.string = settings.dictionaryText
        textView.setAccessibilityLabel("ข้อมูลคำศัพท์เดิมสำหรับซ่อม")
        scroll.documentView = textView
        alert.accessoryView = scroll
        alert.addButton(withTitle: "ตรวจและบันทึก")
        alert.addButton(withTitle: "ยกเลิก")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            _ = try BrandDictionary.rows(textView.string)
            settings.dictionaryText = textView.string
            loadRows()
            clearFields()
            statusLabel.stringValue = "ซ่อมข้อมูลคำศัพท์แล้ว"
        } catch {
            statusLabel.stringValue = "ยังบันทึกไม่ได้: \(error.localizedDescription)"
        }
    }

    @objc private func exportVocabulary() {
        guard let settings else { return }
        do {
            let data = try BrandDictionary.exportData(settings.dictionaryText)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "Pink-voices-vocabulary.json"
            panel.allowedContentTypes = [.json]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            statusLabel.stringValue = "ส่งออกคำศัพท์แล้ว"
        } catch {
            statusLabel.stringValue = "ส่งออกไม่ได้: \(error.localizedDescription)"
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSSearchField === searchField { filterRows() }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filteredRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else { return nil }
        let item = filteredRows[row]
        let isHeard = tableColumn.identifier.rawValue == "heard"
        let cell = NSTextField(labelWithString: isHeard ? item.alias : item.spelling)
        cell.lineBreakMode = .byTruncatingTail
        cell.setAccessibilityLabel(isHeard ? "คำที่ได้ยิน \(item.alias)" : "คำที่ต้องการ \(item.spelling)")
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let index = table.selectedRow
        guard filteredRows.indices.contains(index) else {
            selectedAlias = nil
            deleteButton.isEnabled = false
            return
        }
        let item = filteredRows[index]
        selectedAlias = item.alias
        heardField.stringValue = item.alias
        spellingField.stringValue = item.spelling
        saveButton.title = "อัปเดตคำ"
        deleteButton.isEnabled = true
        statusLabel.stringValue = "แก้ไขคู่คำ แล้วกดอัปเดตคำเพื่อบันทึก"
    }
}
