import AppKit

/// Borderless, non-activating panel: it takes keyboard input without activating the app,
/// so AeroSpace's focus stays where it was.
final class OverlayPanel: NSPanel {
    /// Sees every key first; returns true when it handled it, otherwise the key goes on
    /// to the focused control (the rename field or the search field).
    var keyHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let handler = keyHandler, handler(event) { return }
        super.sendEvent(event)
    }
}

final class PanelController: NSObject, NSWindowDelegate {
    private let panel: OverlayPanel
    private let snapshots: SnapshotStore
    private var keyMap: [String: String] = [:]
    private var cards: [String: CardView] = [:]
    private var order: [String] = []
    private var columns = 1
    private var selected = 0

    private enum Mode { case grid, windows }
    private var mode = Mode.grid
    private var entries: [WindowEntry] = []
    private var listView: WindowListView?

    init(snapshots: SnapshotStore) {
        self.snapshots = snapshots
        panel = OverlayPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        snapshots.onUpdate = { [weak self] workspace in
            guard let self, self.panel.isVisible else { return }
            self.cards[workspace]?.setImage(self.snapshots.images[workspace])
        }
    }

    var isShown: Bool { panel.isVisible }

    /// ⌥A: closed → workspace grid → window lister → workspace grid → …
    func toggle() {
        guard isShown else { show(); return }
        mode == .grid ? showWindowList() : showGrid()
    }

    func show() {
        mode = .grid
        let windows = AeroSpace.windows()
        let visible = AeroSpace.visible()
        let focused = AeroSpace.focused()
        let visibleNames = Set(visible.map(\.workspace))

        var byWorkspace: [String: [AeroWindow]] = [:]
        for window in windows { byWorkspace[window.workspace, default: []].append(window) }
        // Always show every workspace, empty ones too, so the grid never changes shape.
        let names = Set(AeroSpace.allWorkspaces()).union(byWorkspace.keys).union(visibleNames).sorted(by: AeroSpace.order)

        keyMap = [:]
        let labels = WorkspaceNames.all()
        let infos: [WorkspaceInfo] = names.map { name in
            var key = WorkspaceInfo.key(for: name)
            if keyMap[key] != nil { key = "" }
            if !key.isEmpty { keyMap[key] = name }
            return WorkspaceInfo(name: name, key: key, windows: byWorkspace[name] ?? [],
                                 isFocused: name == focused, isVisible: visibleNames.contains(name),
                                 label: labels[name])
        }

        self.windows = windows
        self.focused = focused
        chromeTabs = []
        rebuildEntries()
        loadChromeTabs()

        self.infos = infos
        layout(infos)
        select(order.firstIndex(of: focused ?? "") ?? 0)
        panel.makeKeyAndOrderFront(nil)
        snapshots.refresh(windows: windows, visible: visibleNames)
    }

    private var infos: [WorkspaceInfo] = []
    private var windows: [AeroWindow] = []
    private var focused: String?
    private var chromeTabs: [ChromeTab] = []

    /// Tabs come in asynchronously (AppleScript is slow); the lister updates when they arrive.
    private func loadChromeTabs() {
        guard Chrome.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let tabs = Chrome.tabs()
            DispatchQueue.main.async {
                guard let self, self.isShown else { return }
                self.chromeTabs = tabs
                self.rebuildEntries()
                self.listView?.update(entries: self.entries)
            }
        }
    }

    /// One entry per window, except Chrome windows, which become one entry per tab.
    private func rebuildEntries() {
        let labels = WorkspaceNames.all()
        let tabsByWindow = Dictionary(grouping: chromeTabs, by: \.windowId)
        var unmatchedChromeWindows = Set(tabsByWindow.keys)

        func workspaceTitle(_ workspace: String) -> String {
            labels[workspace].map { "\(workspace) · \($0)" } ?? workspace
        }

        var result: [WindowEntry] = []
        let sorted = windows.sorted { $0.workspace != $1.workspace ? AeroSpace.order($0.workspace, $1.workspace) : false }
        for window in sorted {
            let base = WindowEntry(window: window, workspaceTitle: workspaceTitle(window.workspace),
                                   line: WorkspaceInfo.line(for: window),
                                   isFocusedWorkspace: window.workspace == focused, tab: nil)
            // Chrome titles its windows "<active tab title> - Google Chrome – <profile>".
            guard window.bundleId == Chrome.bundleId,
                  let chromeId = unmatchedChromeWindows.first(where: { id in
                      let name = tabsByWindow[id]?.first?.windowName ?? ""
                      return !name.isEmpty && (window.title == name || window.title.hasPrefix(name + " - "))
                  }),
                  let tabs = tabsByWindow[chromeId] else {
                result.append(base)
                continue
            }
            unmatchedChromeWindows.remove(chromeId)
            for tab in tabs {
                result.append(WindowEntry(window: window, workspaceTitle: base.workspaceTitle,
                                          line: "\(tab.title) · \(tab.host)",
                                          isFocusedWorkspace: base.isFocusedWorkspace, tab: tab))
            }
        }
        entries = result
    }

    private func showGrid() {
        mode = .grid
        listView = nil
        let current = order.indices.contains(selected) ? selected : 0
        // Re-read names so a rename shows up, then rebuild the grid in place.
        let labels = WorkspaceNames.all()
        infos = infos.map { var info = $0; info.label = labels[info.name]; return info }
        layout(infos)
        select(current)
    }

    private func showWindowList() {
        mode = .windows
        let list = WindowListView(entries: entries)
        list.onChoose = { [weak self] entry in self?.choose(entry) }
        list.onClose = { [weak self] in self?.hide() }
        listView = list
        place(list, size: list.frame.size, cornerRadius: 14)
        list.focusSearch()
    }

    func hide() {
        panel.orderOut(nil)
        listView = nil
        mode = .grid
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    private func choose(_ workspace: String) {
        hide()
        DispatchQueue.global(qos: .userInteractive).async { AeroSpace.switchTo(workspace) }
    }

    private func choose(_ entry: WindowEntry) {
        hide()
        DispatchQueue.global(qos: .userInteractive).async {
            if let tab = entry.tab { Chrome.activate(tab) }
            AeroSpace.focus(windowId: entry.window.windowId)
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if mode == .windows { return listView?.handleKey(event) ?? false }
        if panel.firstResponder is NSTextView { return false }      // renaming: keys go to the field
        handleGridKey(event)
        return true
    }

    private func handleGridKey(_ event: NSEvent) {
        switch event.keyCode {
        case 53: hide(); return                                     // Esc
        case 36, 76: if order.indices.contains(selected) { choose(order[selected]) }; return  // Return, Enter
        case 123: move(dx: -1, dy: 0); return                       // arrows
        case 124: move(dx: 1, dy: 0); return
        case 125: move(dx: 0, dy: 1); return
        case 126: move(dx: 0, dy: -1); return
        default: break
        }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let chars = event.charactersIgnoringModifiers?.lowercased() else { return }
        switch chars {
        case "h": move(dx: -1, dy: 0)
        case "l": move(dx: 1, dy: 0)
        case "j": move(dx: 0, dy: 1)
        case "k": move(dx: 0, dy: -1)
        case "n": if order.indices.contains(selected) { cards[order[selected]]?.beginRename() }
        default:
            if let workspace = keyMap[chars] { choose(workspace) }
        }
    }

    /// Moves the selection in the grid. Left/right wrap across rows; up/down stop at the edges.
    private func move(dx: Int, dy: Int) {
        guard !order.isEmpty else { return }
        var next = selected
        if dx != 0 {
            next = (selected + dx + order.count) % order.count
        } else {
            let target = selected + dy * columns
            if order.indices.contains(target) { next = target }
            else if dy > 0, selected / columns < (order.count - 1) / columns { next = order.count - 1 }  // ragged last row
        }
        select(next)
    }

    private func select(_ index: Int) {
        guard order.indices.contains(index) else { return }
        if order.indices.contains(selected) { cards[order[selected]]?.isSelected = false }
        selected = index
        cards[order[index]]?.isSelected = true
    }

    private func layout(_ infos: [WorkspaceInfo]) {
        let area = currentScreen().visibleFrame

        let count = max(infos.count, 1)
        let columns = count <= 4 ? count : (count <= 8 ? 4 : 5)
        let rows = Int(ceil(Double(count) / Double(columns)))
        let pad: CGFloat = 18
        let gap: CGFloat = 12

        // Cards are 320pt wide unless that would overflow the screen.
        let maxCardWidth = (area.width * 0.92 - pad * 2 - gap * CGFloat(columns - 1)) / CGFloat(columns)
        var cardWidth = min(320, maxCardWidth)
        var cardHeight = CardView.height(forWidth: cardWidth)
        let maxCardHeight = (area.height * 0.92 - pad * 2 - gap * CGFloat(rows - 1)) / CGFloat(rows)
        if cardHeight > maxCardHeight {
            cardWidth *= maxCardHeight / cardHeight
            cardHeight = CardView.height(forWidth: cardWidth)
        }

        let width = pad * 2 + CGFloat(columns) * cardWidth + CGFloat(columns - 1) * gap
        let footer: CGFloat = 20
        let height = pad * 2 + footer + CGFloat(rows) * cardHeight + CGFloat(rows - 1) * gap

        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.material = .hudWindow
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 16
        root.layer?.masksToBounds = true

        let hint = NSTextField(labelWithString: "hjkl move   ⏎ go   n name   ⌥A windows   esc close")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        hint.frame = NSRect(x: pad, y: pad - 4, width: width - pad * 2, height: 16)
        root.addSubview(hint)

        cards = [:]
        order = infos.map(\.name)
        self.columns = columns
        for (index, info) in infos.enumerated() {
            let column = index % columns
            let row = index / columns
            let x = pad + CGFloat(column) * (cardWidth + gap)
            let y = height - pad - CGFloat(row + 1) * cardHeight - CGFloat(row) * gap
            let card = CardView(frame: NSRect(x: x, y: y, width: cardWidth, height: cardHeight),
                                info: info, image: snapshots.images[info.name])
            card.onClick = { [weak self] workspace in self?.choose(workspace) }
            card.onRename = { workspace, name in WorkspaceNames.set(name, for: workspace) }
            root.addSubview(card)
            cards[info.name] = card
        }

        place(root, size: NSSize(width: width, height: height), cornerRadius: 16)
    }

    /// Puts `content` in the panel on a blurred background, centred on the screen with the mouse.
    private func place(_ content: NSView, size: NSSize, cornerRadius: CGFloat) {
        let area = currentScreen().visibleFrame
        let root: NSView
        if let effect = content as? NSVisualEffectView {
            root = effect
        } else {
            let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = cornerRadius
            effect.layer?.masksToBounds = true
            effect.addSubview(content)
            root = effect
        }
        panel.contentView = root
        panel.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
    }

    private func currentScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
    }
}
