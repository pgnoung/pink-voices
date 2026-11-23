import AppKit
import Foundation

/// A compact, local-only view of Sol API usage. It renders ledger metadata only,
/// never transcript or prompt text.
enum SolUsageWindow {
    private static var controller: SolUsageWindowController?

    static func show() {
        let controller = controller ?? SolUsageWindowController()
        self.controller = controller
        controller.present()
    }
}

private final class SolUsageWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let latestLabel = NSTextField(wrappingLabelWithString: "")
    private let totalLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let historyTable = NSTableView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let refreshButton = NSButton(title: "รีเฟรช", target: nil, action: nil)
    private var observers: [NSObjectProtocol] = []
    private var calls = [SolUsageCall]()

    init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 570),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(Brand.name) • การใช้ Sol"
        PinkTheme.style(window)
        window.minSize = NSSize(width: 410, height: 390)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildWindow()
        observeLedger()
    }

    required init?(coder: NSCoder) { nil }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func present() {
        reload()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildWindow() {
        guard let content = window?.contentView else { return }
        let headline = NSTextField(labelWithString: "การใช้ Sol")
        headline.font = .systemFont(ofSize: 21, weight: .bold)
        headline.textColor = pink
        headline.setAccessibilityLabel("สรุปการใช้ Sol")

        latestLabel.font = .systemFont(ofSize: 13, weight: .medium)
        latestLabel.maximumNumberOfLines = 3
        latestLabel.setAccessibilityLabel("ประมาณการล่าสุด")
        totalLabel.font = .monospacedDigitSystemFont(ofSize: 20, weight: .bold)
        totalLabel.textColor = pink
        totalLabel.setAccessibilityLabel("ยอดประมาณการสะสม")
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 3
        detailLabel.setAccessibilityLabel("รายละเอียดการคิดราคา")

        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        refreshButton.bezelStyle = .rounded
        refreshButton.setAccessibilityLabel("รีเฟรชประวัติการใช้ Sol")

        let summary = NSStackView(views: [latestLabel, totalLabel, detailLabel])
        summary.orientation = .vertical
        summary.spacing = 5
        let summaryBox = NSBox()
        summaryBox.boxType = .custom
        summaryBox.borderColor = pink.withAlphaComponent(0.25)
        summaryBox.fillColor = pink.withAlphaComponent(0.06)
        summaryBox.cornerRadius = 10
        summaryBox.contentViewMargins = NSSize(width: 12, height: 10)
        summary.translatesAutoresizingMaskIntoConstraints = false
        summaryBox.contentView?.addSubview(summary)
        NSLayoutConstraint.activate([
            summary.leadingAnchor.constraint(equalTo: summaryBox.contentView!.leadingAnchor),
            summary.trailingAnchor.constraint(equalTo: summaryBox.contentView!.trailingAnchor),
            summary.topAnchor.constraint(equalTo: summaryBox.contentView!.topAnchor),
            summary.bottomAnchor.constraint(equalTo: summaryBox.contentView!.bottomAnchor)
        ])

        let historyTitle = NSTextField(labelWithString: "รายการที่ติดตาม")
        historyTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        historyTitle.setAccessibilityLabel("ประวัติการเรียก Sol")
        let historyScroll = NSScrollView()
        historyScroll.hasVerticalScroller = true
        historyScroll.autohidesScrollers = true
        historyScroll.borderType = .lineBorder
        historyTable.headerView = nil
        historyTable.rowHeight = 105
        historyTable.intercellSpacing = NSSize(width: 0, height: 6)
        historyTable.usesAlternatingRowBackgroundColors = false
        historyTable.delegate = self
        historyTable.dataSource = self
        historyTable.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("usage")))
        historyScroll.documentView = historyTable
        historyScroll.setAccessibilityLabel("รายการเรียก Sol ที่ติดตามแล้ว")

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.maximumNumberOfLines = 2
        emptyLabel.setAccessibilityLabel("สถานะประวัติการใช้ Sol")

        let top = NSStackView(views: [headline, refreshButton])
        top.orientation = .horizontal
        top.alignment = .centerY
        headline.setContentHuggingPriority(.defaultLow, for: .horizontal)
        refreshButton.setContentHuggingPriority(.required, for: .horizontal)
        let root = NSStackView(views: [top, summaryBox, historyTitle, historyScroll, emptyLabel])
        root.orientation = .vertical
        root.spacing = 11
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            historyScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 190)
        ])
    }

    private func observeLedger() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .solUsageLedgerDidChange, object: nil, queue: .main) { [weak self] _ in self?.reload() },
            center.addObserver(forName: .solUsageLedgerPersistenceFailed, object: nil, queue: .main) { [weak self] _ in self?.reload() }
        ]
    }

    @objc private func refresh() { reload() }

    private func reload() {
        let snapshot = SolUsageLedger.shared.snapshot()
        let rate = snapshot.lastEstimate?.exchangeRateTHBPerUSD ?? snapshot.calls.compactMap(\.estimate).first?.exchangeRateTHBPerUSD
        let hasPersistenceFailure = snapshot.lastError?.isEmpty == false
        totalLabel.stringValue = hasPersistenceFailure && snapshot.calls.isEmpty
            ? "ยอดสะสม: ยังยืนยันไม่ได้"
            : "สะสมประมาณ\(hasPersistenceFailure ? " (อาจไม่ครบ)" : "") \(thb(snapshot.totalEstimatedTHB))"
        detailLabel.stringValue = [
            hasPersistenceFailure ? "บันทึกประวัติไม่สำเร็จ ยอดสะสมที่แสดงอาจไม่ครบ" : nil,
            rate.map { "อัตราคงที่ 1 USD = \(decimal($0)) THB" },
            snapshot.unpricedCount > 0 ? "ยังประเมินราคาไม่ได้ \(snapshot.unpricedCount) ครั้ง" : nil,
            snapshot.missingTokenCount > 0 ? "ข้อมูล token ยังไม่ครบ \(snapshot.missingTokenCount) ครั้ง" : nil
        ].compactMap { $0 }.joined(separator: " • ")
        if detailLabel.stringValue.isEmpty { detailLabel.stringValue = "ยอดรวมเริ่มนับจากการเรียกที่ติดตามได้ แม้ข้อมูลบางส่วนยังไม่ครบ" }

        calls = snapshot.calls
        if let latest = calls.first {
            latestLabel.stringValue = "ล่าสุด: \(callStatus(latest))"
        } else if let error = snapshot.lastError, !error.isEmpty {
            latestLabel.stringValue = "ล่าสุด: ผิดพลาด \(error)"
        } else {
            latestLabel.stringValue = "ล่าสุด: ยังไม่มีราคาที่ยืนยันได้"
        }

        historyTable.reloadData()
        emptyLabel.isHidden = !calls.isEmpty
        emptyLabel.stringValue = "ยังไม่มีการเรียก Sol ที่ติดตามได้ รายการนี้ไม่เก็บข้อความที่พูดหรือ prompt"
        window?.title = "\(Brand.name) • การใช้ Sol (\(snapshot.calls.count))"
    }

    func numberOfRows(in tableView: NSTableView) -> Int { calls.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard calls.indices.contains(row) else { return nil }
        return callView(calls[row])
    }

    private func callView(_ call: SolUsageCall) -> NSView {
        let title = NSTextField(labelWithString: "\(date(call.timestamp))  •  \(call.model ?? "ไม่ทราบรุ่น")")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        let status = NSTextField(wrappingLabelWithString: callStatus(call))
        status.font = .systemFont(ofSize: 12)
        status.textColor = statusColor(call)
        status.maximumNumberOfLines = 2
        let tokens = NSTextField(wrappingLabelWithString: tokenSummary(call))
        tokens.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        tokens.textColor = .secondaryLabelColor
        tokens.maximumNumberOfLines = 2
        let stack = NSStackView(views: [title, status, tokens])
        stack.orientation = .vertical
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 9, bottom: 8, right: 9)
        stack.setAccessibilityLabel("การเรียก \(date(call.timestamp)): \(callStatus(call)); \(tokenSummary(call))")
        let box = NSBox()
        box.boxType = .custom
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.cornerRadius = 7
        box.contentViewMargins = .zero
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: box.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: box.contentView!.bottomAnchor)
        ])
        let cell = NSTableCellView()
        box.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(box)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            box.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            box.topAnchor.constraint(equalTo: cell.topAnchor),
            box.bottomAnchor.constraint(equalTo: cell.bottomAnchor)
        ])
        return cell
    }

    private func callStatus(_ call: SolUsageCall) -> String {
        if let error = call.transportErrorCode, !error.isEmpty { return "ผิดพลาด: \(error)" }
        if let status = call.httpStatus, !(200...299).contains(status) { return "ผิดพลาด: HTTP \(status)" }
        if call.status == "pending" { return "ยังไม่ได้รับรายงานโทเคนจาก Sol" }
        guard let estimate = call.estimate else {
            return call.inputTokens == nil || call.outputTokens == nil
                ? "ไม่ทราบราคา: ข้อมูล token ขาเข้าหรือขาออกไม่ครบ"
                : "ไม่ทราบราคา: ยังไม่มีอัตราที่ใช้ได้"
        }
        return "\(estimate.isComplete ? "ประมาณ" : "ประมาณการบางส่วน") \(thb(estimate.thb)) (\(usd(estimate.usd)))"
    }

    private func statusColor(_ call: SolUsageCall) -> NSColor {
        if call.transportErrorCode != nil || (call.httpStatus.map { !(200...299).contains($0) } ?? false) { return .systemRed }
        return call.estimate == nil ? .systemOrange : .labelColor
    }

    private func tokenSummary(_ call: SolUsageCall) -> String {
        var parts = [String]()
        if let input = call.inputTokens { parts.append("ขาเข้า \(input)") }
        if let cached = call.cachedInputTokens { parts.append("ขาเข้าจากแคช \(cached)") }
        if let cacheWrite = call.cacheWriteTokens { parts.append("เขียนแคช \(cacheWrite)") }
        if let output = call.outputTokens { parts.append("ขาออก \(output)") }
        if let reasoning = call.reasoningTokens { parts.append("เหตุผล \(reasoning), รวมในขาออก") }
        if let total = call.totalTokens { parts.append("รวม \(total)") }
        return parts.isEmpty ? "โทเคน: ไม่ได้รับข้อมูล" : "โทเคน: " + parts.joined(separator: " • ")
    }

    private var pink: NSColor { NSColor(calibratedRed: 0.89, green: 0.25, blue: 0.52, alpha: 1) }

    private func thb(_ value: Decimal) -> String {
        let formatted = number(value, digits: 6)
        return value > 0 && formatted == "0" ? "฿<0.000001" : "฿" + formatted
    }
    private func usd(_ value: Decimal) -> String { "$" + number(value, digits: 6) }
    private func decimal(_ value: Decimal) -> String { number(value, digits: 6) }

    private func number(_ value: Decimal, digits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = digits
        return formatter.string(from: value as NSDecimalNumber) ?? "0"
    }

    private func date(_ value: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "th_TH")
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: value)
    }
}
