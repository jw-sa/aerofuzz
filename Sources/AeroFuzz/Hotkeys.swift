import AppKit

/// The keys of one binding, or of a family of bindings that share one line.
struct Shortcut {
    let modifiers: [String]   // glyphs in macOS order: ⌃ ⌥ ⇧ ⌘
    let keys: [String]
    let isRange: Bool         // keys are the first and last of a run, drawn "1 … 0"
}

/// One line of the overview. Bindings that differ only in a number or a direction share a
/// line: ⌘ 1…0 "Go to workspace 1–10", ⌥ H J K L "Focus window ← ↓ ↑ →".
struct HotkeyRow {
    let shortcut: Shortcut
    let text: String
}

struct HotkeySection {
    let title: String
    let entry: Shortcut?      // for a binding mode: the main-mode key that enters it
    let rows: [HotkeyRow]
}

/// Turns AeroSpace's bindings into readable, grouped sections.
enum Hotkeys {
    private static let modifierOrder = ["ctrl", "alt", "shift", "cmd"]
    private static let modifierGlyphs = ["ctrl": "⌃", "alt": "⌥", "shift": "⇧", "cmd": "⌘"]
    private static let directions = ["left", "down", "up", "right"]   // hjkl order
    private static let arrows = ["left": "←", "down": "↓", "up": "↑", "right": "→"]
    /// Commands whose up/down/left/right mean a place on screen (unlike `volume up`).
    private static let directionalVerbs: Set = ["focus", "move", "swap", "join-with", "focus-monitor",
                                                "move-workspace-to-monitor", "move-node-to-monitor"]
    private static let keyGlyphs = [
        "left": "←", "down": "↓", "up": "↑", "right": "→",
        "enter": "↩", "keypadEnter": "⌤", "tab": "⇥", "backspace": "⌫", "forwardDelete": "⌦",
        "pageUp": "⇞", "pageDown": "⇟", "home": "↖", "end": "↘", "space": "space", "esc": "esc",
        "minus": "-", "equal": "=", "period": ".", "comma": ",", "slash": "/", "backslash": "\\",
        "quote": "'", "semicolon": ";", "backtick": "`", "leftSquareBracket": "[", "rightSquareBracket": "]",
        "sectionSign": "§",
    ]

    /// Main-mode sections in this order, by the command's verb; unknown verbs land in the last.
    private static let categories: [(title: String, verbs: [String])] = [
        ("Workspaces", ["workspace", "workspace-back-and-forth", "move-node-to-workspace", "summon-workspace"]),
        ("Windows", ["focus", "focus-back-and-forth", "move", "swap", "join-with", "fullscreen",
                     "macos-native-fullscreen", "macos-native-minimize", "close", "close-all-windows-but-current"]),
        ("Layout", ["layout", "split", "resize", "balance-sizes", "flatten-workspace-tree"]),
        ("Monitors", ["focus-monitor", "move-workspace-to-monitor", "move-node-to-monitor"]),
        ("Other", ["mode", "reload-config", "enable", "volume", "exec-and-forget"]),
    ]

    /// Stands in for the part that varies within a family until the line's text is built.
    private static let slot = "§"

    /// Main mode split into categories, then one section per other binding mode.
    static func sections(from modes: [String: [String: String]]) -> [HotkeySection] {
        let main = modes["main"] ?? [:]
        let otherModes = modes.keys.filter { $0 != "main" }.sorted()

        // A main-mode key that only enters a mode is shown in that mode's header instead.
        let modeSwitches = Set(otherModes.map { "mode \($0)" })
        let mainLines = lines(for: main.filter { !modeSwitches.contains($0.value) })
        var result: [HotkeySection] = categories.indices.compactMap { index in
            let rows = mainLines.filter { $0.category == index }.map(\.row)
            return rows.isEmpty ? nil : HotkeySection(title: categories[index].title, entry: nil, rows: rows)
        }
        for mode in otherModes {
            let entry = main.keys.sorted().first { main[$0] == "mode \(mode)" }
                .map { key -> Shortcut in
                    let binding = parse(key, "")
                    return Shortcut(modifiers: binding.modifiers.compactMap { modifierGlyphs[$0] },
                                    keys: [keyLabel(binding.key)], isRange: false)
                }
            result.append(HotkeySection(title: "\(mode.capitalized) mode", entry: entry,
                                        rows: lines(for: modes[mode] ?? [:]).map(\.row)))
        }
        return result
    }

    // MARK: Grouping

    private struct Binding {
        let modifiers: [String]   // "ctrl", "alt", … in modifierOrder
        let key: String
        let command: String       // a trailing "mode main" after other commands is dropped
    }

    private struct Line {
        let category: Int
        let rank: Int             // the verb's position in `categories`
        let first: Int            // lowest number or direction in a family, trailing number otherwise
        let command: String
        let row: HotkeyRow
    }

    private static func parse(_ key: String, _ command: String) -> Binding {
        var parts = key.split(separator: "-").map(String.init)
        let last = parts.popLast() ?? key
        var commands = command.components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if commands.count > 1 { commands.removeAll { $0 == "mode main" } }
        return Binding(modifiers: modifierOrder.filter(parts.contains), key: last,
                       command: commands.joined(separator: "; "))
    }

    /// The part that varies within a family: the number bound to a digit key, or a direction.
    /// "move-node-to-workspace 3" → ("move-node-to-workspace §", 3).
    private static func variable(of binding: Binding) -> (template: String, value: Int, isDirection: Bool)? {
        guard !binding.command.contains(";") else { return nil }
        var words = binding.command.split(separator: " ").map(String.init)
        if binding.key.count == 1, binding.key.first!.isNumber, let number = words.last.flatMap({ Int($0) }) {
            words[words.count - 1] = slot
            return (words.joined(separator: " "), number, false)
        }
        if directionalVerbs.contains(words.first ?? ""), let index = words.firstIndex(where: directions.contains) {
            let value = directions.firstIndex(of: words[index])!
            words[index] = slot
            return (words.joined(separator: " "), value, true)
        }
        return nil
    }

    private struct Family {
        let template: String
        let isDirection: Bool
        var members: [(binding: Binding, value: Int)] = []
    }

    private static func lines(for bindings: [String: String]) -> [Line] {
        var families: [String: Family] = [:]
        var singles: [Binding] = []
        for (key, command) in bindings {
            let binding = parse(key, command)
            guard let variable = variable(of: binding) else { singles.append(binding); continue }
            let id = "\(binding.modifiers)|\(variable.isDirection)|\(variable.template)"
            families[id, default: Family(template: variable.template, isDirection: variable.isDirection)]
                .members.append((binding, variable.value))
        }

        var result: [Line] = []
        for family in families.values {
            let (template, isDirection, members) = (family.template, family.isDirection, family.members)
            guard members.count > 1 else {
                singles.append(contentsOf: members.map(\.binding))
                continue
            }
            let sorted = members.sorted { $0.value < $1.value }
            let values = sorted.map(\.value)
            let filled: String
            if isDirection {
                filled = values.map { arrows[directions[$0]]! }.joined(separator: " ")
            } else if values.last! - values.first! == values.count - 1 {
                filled = "\(values.first!)–\(values.last!)"
            } else {
                filled = values.map(String.init).joined(separator: ", ")
            }
            var keys = sorted.map { keyLabel($0.binding.key) }
            let isRange = !isDirection && keys.count > 2
            if isRange { keys = [keys.first!, keys.last!] }
            let shortcut = Shortcut(modifiers: sorted[0].binding.modifiers.compactMap { modifierGlyphs[$0] },
                                    keys: keys, isRange: isRange)
            let row = HotkeyRow(shortcut: shortcut, text: describe(template).replacingOccurrences(of: slot, with: filled))
            let place = rank(of: template)
            result.append(Line(category: place.category, rank: place.rank, first: values[0], command: template, row: row))
        }
        for binding in singles {
            let shortcut = Shortcut(modifiers: binding.modifiers.compactMap { modifierGlyphs[$0] },
                                    keys: [keyLabel(binding.key)], isRange: false)
            let place = rank(of: binding.command)
            let trailing = binding.command.split(separator: " ").last.flatMap { Int($0) } ?? 0
            result.append(Line(category: place.category, rank: place.rank, first: trailing, command: binding.command,
                               row: HotkeyRow(shortcut: shortcut, text: describe(binding.command))))
        }
        return result.sorted {
            ($0.category, $0.rank, $0.first, $0.command, $0.row.shortcut.modifiers.count)
                < ($1.category, $1.rank, $1.first, $1.command, $1.row.shortcut.modifiers.count)
        }
    }

    private static func rank(of command: String) -> (category: Int, rank: Int) {
        let verb = command.split(separator: " ").first.map(String.init) ?? ""
        var rank = 0
        for (index, category) in categories.enumerated() {
            if let position = category.verbs.firstIndex(of: verb) { return (index, rank + position) }
            rank += category.verbs.count
        }
        return (categories.count - 1, rank)
    }

    private static func keyLabel(_ key: String) -> String {
        if let glyph = keyGlyphs[key] { return glyph }
        if key.hasPrefix("keypad") {
            let rest = String(key.dropFirst("keypad".count))
            return "num " + (keyGlyphs[rest.lowercased()] ?? rest)
        }
        return key.count <= 3 ? key.uppercased() : key   // "h" → "H", "f12" → "F12"
    }

    // MARK: Descriptions

    /// Plain-English text for a command; commands it doesn't know are shown as they are.
    static func describe(_ command: String) -> String {
        command.components(separatedBy: "; ").map(describeOne).joined(separator: " + ")
    }

    private static func describeOne(_ command: String) -> String {
        let words = command.split(separator: " ").map(String.init)
        guard let verb = words.first else { return command }
        let args = words.dropFirst().filter { !$0.hasPrefix("--") }
        let arg = args.first ?? ""
        switch verb {
        case "workspace":
            return ["next": "Next workspace", "prev": "Previous workspace"][arg] ?? "Go to workspace \(arg)"
        case "workspace-back-and-forth": return "Last workspace (back and forth)"
        case "move-node-to-workspace":
            return ["next": "Move window to next workspace", "prev": "Move window to previous workspace"][arg]
                ?? "Move window to workspace \(arg)"
        case "summon-workspace": return "Bring workspace \(arg) here"
        case "focus": return "Focus window \(arrow(args))"
        case "focus-back-and-forth": return "Last focused window"
        case "move": return "Move window \(arrow(args))"
        case "swap": return "Swap window \(arrow(args))"
        case "join-with": return "Join with window \(arrow(args))"
        case "fullscreen": return "Toggle fullscreen"
        case "macos-native-fullscreen": return "Toggle native fullscreen"
        case "macos-native-minimize": return "Minimize window"
        case "close": return "Close window"
        case "close-all-windows-but-current": return "Close all other windows"
        case "layout": return layout(args)
        case "split": return "Split \(arg)"
        case "resize": return resize(args)
        case "balance-sizes": return "Balance window sizes"
        case "flatten-workspace-tree": return "Reset layout (flatten tree)"
        case "focus-monitor": return "Focus \(monitor(arg))"
        case "move-workspace-to-monitor": return "Move workspace to \(monitor(arg))"
        case "move-node-to-monitor": return "Move window to \(monitor(arg))"
        case "mode": return arg == "main" ? "Back to main mode" : "\(arg.capitalized) mode"
        case "reload-config": return "Reload config"
        case "enable": return arg == "toggle" ? "Toggle AeroSpace" : "Turn AeroSpace \(arg)"
        case "volume": return volume(args)
        case "exec-and-forget": return "Run " + words.dropFirst().joined(separator: " ")
        default: return command
        }
    }

    /// The direction among `args` as an arrow; the family slot and anything else pass through.
    private static func arrow(_ args: [String]) -> String {
        let direction = args.first { arrows[$0] != nil || $0 == slot } ?? args.joined(separator: " ")
        return arrows[direction] ?? direction
    }

    private static func monitor(_ arg: String) -> String {
        switch arg {
        case "next": return "next monitor"
        case "prev": return "previous monitor"
        default: return "monitor \(arrows[arg] ?? arg)"
        }
    }

    /// `layout a b c` applies the first of a, b, c that isn't the current layout.
    private static func layout(_ args: [String]) -> String {
        if Set(args) == ["floating", "tiling"] { return "Toggle floating / tiling" }
        if let first = args.first, ["tiles", "accordion"].contains(first), Set(args.dropFirst()) == ["horizontal", "vertical"] {
            return "\(first.capitalized) layout, flip orientation"
        }
        let names = ["h_tiles": "horizontal tiles", "v_tiles": "vertical tiles",
                     "h_accordion": "horizontal accordion", "v_accordion": "vertical accordion"]
        let text = args.map { names[$0] ?? $0 }.joined(separator: " / ") + " layout"
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private static func resize(_ args: [String]) -> String {
        guard args.count >= 2 else { return "Resize" }
        let what = ["smart": "window", "smart-opposite": "window (other axis)"][args[0]] ?? args[0]
        let amount = args[1]
        if amount.hasPrefix("+") { return "Grow \(what) by \(amount.dropFirst())" }
        if amount.hasPrefix("-") { return "Shrink \(what) by \(amount.dropFirst())" }
        return "Set \(what) to \(amount)"
    }

    private static func volume(_ args: [String]) -> String {
        switch args.first {
        case "up": return "Volume up"
        case "down": return "Volume down"
        case "mute-toggle": return "Toggle mute"
        case "set": return args.count > 1 && args[1] == "0" ? "Mute" : "Set volume to \(args.dropFirst().joined())"
        default: return "Volume"
        }
    }
}

// MARK: - View

/// Third mode of the panel (? in the grid): every AeroSpace binding, grouped, in columns.
final class HotkeyHelpView: NSView {
    private static let pad: CGFloat = 24
    private static let columnGap: CGFloat = 40
    private static let maxColumnWidth: CGFloat = 370
    private static let titleHeight: CGFloat = 54
    private static let footerHeight: CGFloat = 30
    private static let bodyTop: CGFloat = 14
    private static let headerHeight: CGFloat = 30
    private static let rowHeight: CGFloat = 26
    private static let sectionGap: CGFloat = 18

    override var isFlipped: Bool { true }

    init(sections: [HotkeySection], configPath: String?, maxSize: NSSize) {
        let maxBody = maxSize.height - Self.titleHeight - Self.footerHeight
        let columns = Self.columns(for: sections, maxHeight: maxBody)
        let count = CGFloat(max(columns.count, 1))
        let columnWidth = min(Self.maxColumnWidth, (maxSize.width - Self.pad * 2 - Self.columnGap * (count - 1)) / count)
        let width = max(Self.pad * 2 + count * columnWidth + (count - 1) * Self.columnGap, 440)
        let contentHeight = sections.isEmpty ? 80 : columns.map { Self.height(of: $0) }.max()!
        let bodyHeight = min(contentHeight, maxBody)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.titleHeight + bodyHeight + Self.footerHeight))

        let title = NSTextField(labelWithString: "AeroSpace hotkeys")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor
        title.frame = NSRect(x: Self.pad, y: 18, width: width / 2, height: 20)
        addSubview(title)

        if let configPath {
            let path = NSTextField(labelWithString: (configPath as NSString).abbreviatingWithTildeInPath)
            path.font = .systemFont(ofSize: 11)
            path.textColor = .tertiaryLabelColor
            path.alignment = .right
            path.lineBreakMode = .byTruncatingHead
            path.frame = NSRect(x: width / 2, y: 21, width: width / 2 - Self.pad, height: 16)
            addSubview(path)
        }

        let divider = NSBox()
        divider.boxType = .separator
        divider.frame = NSRect(x: 0, y: Self.titleHeight - 1, width: width, height: 1)
        addSubview(divider)

        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: contentHeight))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: Self.titleHeight, width: width, height: bodyHeight))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = contentHeight > bodyHeight
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        addSubview(scroll)

        if sections.isEmpty {
            let empty = NSTextField(labelWithString: "No bindings — is AeroSpace running?")
            empty.font = .systemFont(ofSize: 13)
            empty.textColor = .tertiaryLabelColor
            empty.alignment = .center
            empty.frame = NSRect(x: 0, y: 30, width: width, height: 18)
            document.addSubview(empty)
        }

        for (index, column) in columns.enumerated() {
            let x = Self.pad + CGFloat(index) * (columnWidth + Self.columnGap)
            var y = Self.bodyTop
            for section in column {
                addHeader(section, x: x, y: y, width: columnWidth, to: document)
                y += Self.headerHeight
                for row in section.rows {
                    addRow(row, x: x, y: y, width: columnWidth, to: document)
                    y += Self.rowHeight
                }
                y += Self.sectionGap
            }
        }

        let hint = NSTextField(labelWithString: "? or esc back")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        hint.frame = NSRect(x: 0, y: bounds.height - Self.footerHeight + 8, width: width, height: 16)
        addSubview(hint)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private static func height(of section: HotkeySection) -> CGFloat {
        headerHeight + CGFloat(section.rows.count) * rowHeight
    }

    private static func height(of column: [HotkeySection]) -> CGFloat {
        bodyTop + column.map { height(of: $0) }.reduce(0, +) + CGFloat(max(column.count - 1, 0)) * sectionGap + 6
    }

    /// The sections, in order, over the fewest columns (at least two) whose tallest fits `maxHeight`.
    private static func columns(for sections: [HotkeySection], maxHeight: CGFloat) -> [[HotkeySection]] {
        guard sections.count > 1 else { return [sections] }
        var columns: [[HotkeySection]] = []
        for count in 2...min(4, sections.count) {
            columns = split(sections, into: count)
            if columns.map({ height(of: $0) }).max()! <= maxHeight { break }
        }
        return columns
    }

    /// Fills columns in reading order; a section moves on to the next column once more than
    /// half of it would stick out past an even share.
    private static func split(_ sections: [HotkeySection], into count: Int) -> [[HotkeySection]] {
        let share = sections.map { height(of: $0) }.reduce(0, +) / CGFloat(count)
        var columns: [[HotkeySection]] = [[]]
        var filled: CGFloat = 0
        for section in sections {
            let sectionHeight = height(of: section)
            if !columns[columns.count - 1].isEmpty, columns.count < count, filled + sectionHeight / 2 > share {
                columns.append([])
                filled = 0
            }
            columns[columns.count - 1].append(section)
            filled += sectionHeight
        }
        return columns
    }

    // MARK: Pieces

    private func addHeader(_ section: HotkeySection, x: CGFloat, y: CGFloat, width: CGFloat, to view: NSView) {
        var right = x + width
        if let entry = section.entry {
            right = addKeycaps(entry, right: right, y: y + 1, to: view) - 10
        }
        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = NSAttributedString(string: section.title.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .kern: 0.8,
        ])
        label.frame = NSRect(x: x, y: y + 4, width: right - x, height: 16)
        view.addSubview(label)

        let rule = NSBox()
        rule.boxType = .separator
        rule.frame = NSRect(x: x, y: y + Self.headerHeight - 5, width: width, height: 1)
        view.addSubview(rule)
    }

    private func addRow(_ row: HotkeyRow, x: CGFloat, y: CGFloat, width: CGFloat, to view: NSView) {
        let left = addKeycaps(row.shortcut, right: x + width, y: y + (Self.rowHeight - KeycapView.height) / 2, to: view)
        let label = NSTextField(labelWithString: row.text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: x, y: y + 4, width: max(left - x - 12, 40), height: 18)
        view.addSubview(label)
    }

    /// Lays out a shortcut's keycaps flush right against `right`; returns their left edge.
    private func addKeycaps(_ shortcut: Shortcut, right: CGFloat, y: CGFloat, to view: NSView) -> CGFloat {
        var caps: [KeycapView] = []
        var gaps: [CGFloat] = []   // before each cap but the first
        func add(_ cap: KeycapView, gap: CGFloat) {
            if !caps.isEmpty { gaps.append(gap) }
            caps.append(cap)
        }
        for modifier in shortcut.modifiers { add(KeycapView(modifier), gap: 3) }
        for (index, key) in shortcut.keys.enumerated() {
            if index > 0 && shortcut.isRange { add(KeycapView("…", bare: true), gap: 3) }
            // A little extra room between the modifiers and the keys they apply to.
            add(KeycapView(key), gap: index == 0 ? 7 : 3)
        }
        let total = caps.map { $0.frame.width }.reduce(0, +) + gaps.reduce(0, +)
        var cursor = right - total
        for (index, cap) in caps.enumerated() {
            if index > 0 { cursor += gaps[index - 1] }
            cap.frame.origin = NSPoint(x: cursor, y: y)
            view.addSubview(cap)
            cursor += cap.frame.width
        }
        return right - total
    }
}

/// A key drawn as a small keycap; `bare` draws just the text (the "…" in a range).
final class KeycapView: NSView {
    static let height: CGFloat = 20
    private let label: NSAttributedString
    private let bare: Bool

    init(_ text: String, bare: Bool = false) {
        self.bare = bare
        label = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: bare ? NSColor.tertiaryLabelColor : NSColor.labelColor,
        ])
        let textWidth = ceil(label.size().width)
        super.init(frame: NSRect(x: 0, y: 0, width: bare ? textWidth + 2 : max(Self.height, textWidth + 12), height: Self.height))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        // Unflipped: the darker lip sits along the bottom edge, the cap's face above it.
        var face = bounds.insetBy(dx: 0.5, dy: 0.5)
        if !bare {
            NSColor(white: 0, alpha: 0.3).setFill()
            NSBezierPath(roundedRect: face, xRadius: 5, yRadius: 5).fill()
            face.origin.y += 1.5
            face.size.height -= 1.5
            let cap = NSBezierPath(roundedRect: face, xRadius: 5, yRadius: 5)
            NSColor.labelColor.withAlphaComponent(0.13).setFill()
            cap.fill()
            NSColor.labelColor.withAlphaComponent(0.16).setStroke()
            cap.lineWidth = 1
            cap.stroke()
        }
        let size = label.size()
        label.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: face.minY + (face.height - size.height) / 2))
    }
}
