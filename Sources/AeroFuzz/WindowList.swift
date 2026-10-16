import AppKit

/// One window in the lister, with the text the fuzzy search runs over.
struct WindowEntry {
    let window: AeroWindow
    let workspaceTitle: String   // "3" or "3 · Docs"
    let line: String             // "Chrome · AgroLog System Documentation"
    let isFocusedWorkspace: Bool
    let tab: ChromeTab?

    /// Tabs are also searchable by URL path, e.g. "clickup", "docs.google".
    var searchText: String { "\(line) \(workspaceTitle) \(tab?.url ?? "")" }
}

/// Second mode of the panel: a search field over every window on every workspace.
final class WindowListView: NSView, NSTextFieldDelegate {
    static let width: CGFloat = 760
    static let rowHeight: CGFloat = 34
    static let maxRows = 12
    static let searchHeight: CGFloat = 52
    static let footerHeight: CGFloat = 24

    static var height: CGFloat { searchHeight + CGFloat(maxRows) * rowHeight + footerHeight }

    var onChoose: ((WindowEntry) -> Void)?
    var onClose: (() -> Void)?

    private var entries: [WindowEntry]
    private var matches: [WindowEntry] = []
    private var selected = 0
    private let search = NSTextField()
    private let rowsView = FlippedView()
    private let scroll = NSScrollView()
    private let empty = NSTextField(labelWithString: "no matching windows")

    init(entries: [WindowEntry]) {
        self.entries = entries
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        build()
        filter()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// New entries (Chrome tabs arrived): re-run the current query.
    func update(entries: [WindowEntry]) {
        self.entries = entries
        filter()
    }

    func focusSearch() {
        window?.makeFirstResponder(search)
    }

    /// Keys the panel hands us before the search field sees them. Returns true when handled.
    func handleKey(_ event: NSEvent) -> Bool {
        let control = event.modifierFlags.contains(.control)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch event.keyCode {
        case 53: onClose?(); return true                               // Esc
        case 36, 76: chooseSelected(); return true                     // Return, Enter
        case 125: move(1); return true                                 // ↓
        case 126: move(-1); return true                                // ↑
        default: break
        }
        if control && (chars == "j" || chars == "n") { move(1); return true }
        if control && (chars == "k" || chars == "p") { move(-1); return true }
        return false
    }

    func controlTextDidChange(_ obj: Notification) {
        filter()
    }

    // MARK: -

    private func filter() {
        let query = search.stringValue.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            matches = entries
        } else {
            let scored = entries.compactMap { entry in
                Fuzzy.score(query, in: entry.searchText).map { (entry, $0) }
            }
            // Stable: equal scores keep workspace order.
            matches = scored.enumerated()
                .sorted { $0.element.1 != $1.element.1 ? $0.element.1 > $1.element.1 : $0.offset < $1.offset }
                .map { $0.element.0 }
        }
        selected = 0
        renderRows()
    }

    private func move(_ delta: Int) {
        guard !matches.isEmpty else { return }
        selected = (selected + delta + matches.count) % matches.count
        renderRows()
    }

    private func chooseSelected() {
        guard matches.indices.contains(selected) else { return }
        onChoose?(matches[selected])
    }

    private func build() {
        search.placeholderString = "Search windows…"
        search.font = .systemFont(ofSize: 18)
        search.isBordered = false
        search.drawsBackground = false
        search.focusRingType = .none
        search.delegate = self
        search.frame = NSRect(x: 18, y: Self.height - Self.searchHeight + 12, width: Self.width - 36, height: 28)
        addSubview(search)

        let divider = NSBox()
        divider.boxType = .separator
        divider.frame = NSRect(x: 0, y: Self.height - Self.searchHeight, width: Self.width, height: 1)
        addSubview(divider)

        scroll.frame = NSRect(x: 0, y: Self.footerHeight, width: Self.width,
                              height: CGFloat(Self.maxRows) * Self.rowHeight)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = rowsView
        addSubview(scroll)

        empty.font = .systemFont(ofSize: 13)
        empty.textColor = .tertiaryLabelColor
        empty.alignment = .center
        empty.frame = NSRect(x: 0, y: scroll.frame.midY, width: Self.width, height: 18)
        addSubview(empty)

        let hint = NSTextField(labelWithString: "type to filter   ↑↓ / ⌃j ⌃k move   ⏎ go   ⌥A workspaces   esc close")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        hint.frame = NSRect(x: 0, y: 4, width: Self.width, height: 16)
        addSubview(hint)
    }

    private func renderRows() {
        rowsView.subviews.forEach { $0.removeFromSuperview() }
        let width = Self.width
        rowsView.frame = NSRect(x: 0, y: 0, width: width, height: CGFloat(matches.count) * Self.rowHeight)
        empty.isHidden = !matches.isEmpty

        for (index, entry) in matches.enumerated() {
            let row = WindowRowView(frame: NSRect(x: 8, y: CGFloat(index) * Self.rowHeight, width: width - 16, height: Self.rowHeight),
                                    entry: entry, isSelected: index == selected)
            row.onClick = { [weak self] in self?.onChoose?(entry) }
            rowsView.addSubview(row)
        }

        let selectedRect = NSRect(x: 0, y: CGFloat(selected) * Self.rowHeight, width: width, height: Self.rowHeight)
        rowsView.scrollToVisible(selectedRect)
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class WindowRowView: NSView {
    var onClick: (() -> Void)?

    init(frame: NSRect, entry: WindowEntry, isSelected: Bool) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 7
        if isSelected { layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor }

        let iconSize: CGFloat = 20
        let midY = (frame.height - iconSize) / 2
        if let bundleId = entry.window.bundleId,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: url.path))
            icon.frame = NSRect(x: 10, y: midY, width: iconSize, height: iconSize)
            addSubview(icon)
        }

        let badgeWidth: CGFloat = 150
        let badge = NSTextField(labelWithString: entry.workspaceTitle)
        badge.font = .systemFont(ofSize: 12, weight: entry.isFocusedWorkspace ? .semibold : .regular)
        badge.textColor = isSelected ? .white : .secondaryLabelColor
        badge.alignment = .right
        badge.lineBreakMode = .byTruncatingTail
        badge.frame = NSRect(x: frame.width - badgeWidth - 12, y: (frame.height - 16) / 2, width: badgeWidth, height: 16)
        addSubview(badge)

        let title = NSTextField(labelWithString: entry.line)
        title.font = .systemFont(ofSize: 13)
        title.textColor = isSelected ? .white : .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: 40, y: (frame.height - 18) / 2, width: frame.width - 40 - badgeWidth - 24, height: 18)
        addSubview(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
