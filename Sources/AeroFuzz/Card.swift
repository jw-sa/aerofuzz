import AppKit

/// Everything the panel shows about one workspace.
struct WorkspaceInfo {
    let name: String
    let key: String
    let windows: [AeroWindow]
    let isFocused: Bool
    let isVisible: Bool
    var label: String?

    var title: String { label ?? "Workspace \(name)" }

    /// Panel commands (hjkl move, n name), so never used as workspace keys.
    static let reservedKeys: Set<String> = ["h", "j", "k", "l", "n"]

    /// Workspace 1–9 → "1"–"9", 10 → "0", 11–20 → q…p (the row under the numbers, like cmd-alt-N).
    static func key(for workspace: String) -> String {
        if let n = Int(workspace) {
            if (1...9).contains(n) { return String(n) }
            if n == 10 { return "0" }
            let row = Array("qwertyuiop")
            if (11...20).contains(n) { return String(row[n - 11]) }
        }
        let key = String(workspace.lowercased().prefix(1))
        return reservedKeys.contains(key) ? "" : key
    }

    /// One readable line per window, e.g. "Chrome · AgroLog System Documentation".
    var lines: [String] { windows.map(Self.line) }

    static func line(for window: AeroWindow) -> String {
        var title = window.title
        for noise in [" - Google Chrome", " - High memory usage"] {
            if let range = title.range(of: noise) { title = String(title[..<range.lowerBound]) }
        }
        title = title.trimmingCharacters(in: .whitespaces)
        let app = window.appName == "Google Chrome" ? "Chrome" : window.appName
        return title.isEmpty || title == window.appName ? app : "\(app) · \(title)"
    }

    var bundleIds: [String] {
        var seen: [String] = []
        for id in windows.compactMap(\.bundleId) where !seen.contains(id) { seen.append(id) }
        return seen
    }
}

final class CardView: NSView, NSTextFieldDelegate {
    static let bodyLines = 4
    static let lineHeight: CGFloat = 15
    static let headerHeight: CGFloat = 24
    static let pad: CGFloat = 8

    static func height(forWidth width: CGFloat) -> CGFloat {
        let imageHeight = (width - pad * 2) * 9 / 16
        return pad + CGFloat(bodyLines) * lineHeight + 4 + headerHeight + 6 + imageHeight + pad
    }

    private(set) var info: WorkspaceInfo
    var onClick: ((String) -> Void)?
    /// Called with the new name when a rename is committed (Enter), not when cancelled (Esc).
    var onRename: ((String, String) -> Void)?
    private let titleLabel = NSTextField(labelWithString: "")
    private var editor: NSTextField?
    var isEditing: Bool { editor != nil }
    private let imageView = NSImageView()
    private let placeholder = NSTextField(labelWithString: "no snapshot yet")

    init(frame: NSRect, info: WorkspaceInfo, image: NSImage?) {
        self.info = info
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        build()
        placeholder.stringValue = info.windows.isEmpty ? "empty" : "capturing…"
        setImage(image)
        updateStyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The hjkl cursor. Shown as a bright card; the focused workspace keeps its accent border.
    var isSelected = false {
        didSet { updateStyle() }
    }

    private func updateStyle() {
        layer?.backgroundColor = NSColor(white: 1, alpha: isSelected ? 0.24 : 0.07).cgColor
        if info.isFocused {
            layer?.borderWidth = 2
            layer?.borderColor = NSColor.controlAccentColor.cgColor
        } else if isSelected {
            layer?.borderWidth = 2
            layer?.borderColor = NSColor(white: 1, alpha: 0.9).cgColor
        } else if info.isVisible {
            layer?.borderWidth = 1
            layer?.borderColor = NSColor(white: 1, alpha: 0.35).cgColor
        } else {
            layer?.borderWidth = 0
        }
    }

    func setImage(_ image: NSImage?) {
        imageView.image = image
        placeholder.isHidden = image != nil
    }

    // Clicks anywhere on the card select it, not the subviews (except the name editor).
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let editor, editor.frame.contains(convert(point, from: superview)) { return super.hitTest(point) }
        return frame.contains(point) ? self : nil
    }

    // MARK: Renaming

    func beginRename() {
        guard editor == nil else { return }
        let field = NSTextField(string: info.label ?? "")
        field.placeholderString = "Name for workspace \(info.name)"
        field.font = titleLabel.font
        field.focusRingType = .none
        field.bezelStyle = .roundedBezel
        field.delegate = self
        let x = titleLabel.frame.minX - 4
        field.frame = NSRect(x: x, y: titleLabel.frame.minY - 3, width: bounds.width - x - Self.pad, height: 24)
        addSubview(field)
        titleLabel.isHidden = true
        editor = field
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { endRename(save: true); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { endRename(save: false); return true }
        return false
    }

    private func endRename(save: Bool) {
        guard let field = editor else { return }
        editor = nil
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        window?.makeFirstResponder(nil)
        field.removeFromSuperview()
        titleLabel.isHidden = false
        guard save else { return }
        info.label = name.isEmpty ? nil : name
        titleLabel.stringValue = info.title
        onRename?(info.name, name)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(info.name)
    }

    private func build() {
        let pad = Self.pad
        let width = bounds.width

        var y = pad
        let lines = info.lines
        let shown = lines.isEmpty ? ["empty"] : Array(lines.prefix(Self.bodyLines))
        for (index, text) in shown.enumerated().reversed() {
            var line = text
            if index == Self.bodyLines - 1 && lines.count > Self.bodyLines {
                line = "+\(lines.count - Self.bodyLines + 1) more"
            }
            let label = NSTextField(labelWithString: line)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            let row = CGFloat(Self.bodyLines - 1 - index)
            label.frame = NSRect(x: pad, y: y + row * Self.lineHeight, width: width - pad * 2, height: Self.lineHeight)
            addSubview(label)
        }
        y += CGFloat(Self.bodyLines) * Self.lineHeight + 4

        let badge = NSTextField(labelWithString: info.key.uppercased())
        badge.font = .monospacedSystemFont(ofSize: 13, weight: .bold)
        badge.alignment = .center
        badge.textColor = .white
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 5
        badge.layer?.backgroundColor = (info.isFocused ? NSColor.controlAccentColor : NSColor(white: 1, alpha: 0.18)).cgColor
        badge.frame = NSRect(x: pad, y: y + 2, width: 22, height: 20)
        addSubview(badge)

        titleLabel.stringValue = info.title
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        var iconX = width - pad - 18
        for bundleId in info.bundleIds.prefix(6) {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { continue }
            let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: url.path))
            icon.frame = NSRect(x: iconX, y: y + 3, width: 18, height: 18)
            addSubview(icon)
            iconX -= 20
        }
        titleLabel.frame = NSRect(x: pad + 30, y: y + 3, width: max(40, iconX + 14 - pad - 30), height: 18)
        y += Self.headerHeight + 6

        let imageFrame = NSRect(x: pad, y: y, width: width - pad * 2, height: bounds.height - y - pad)
        imageView.frame = imageFrame
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        imageView.layer?.backgroundColor = NSColor(white: 0, alpha: 0.3).cgColor
        addSubview(imageView)

        placeholder.font = .systemFont(ofSize: 11)
        placeholder.textColor = .tertiaryLabelColor
        placeholder.alignment = .center
        placeholder.frame = NSRect(x: imageFrame.minX, y: imageFrame.midY - 8, width: imageFrame.width, height: 16)
        addSubview(placeholder)
    }
}
