import Foundation

struct AeroWindow: Decodable {
    let windowId: Int
    let workspace: String
    let appName: String
    let bundleId: String?
    let title: String

    enum CodingKeys: String, CodingKey {
        case windowId = "window-id"
        case workspace
        case appName = "app-name"
        case bundleId = "app-bundle-id"
        case title = "window-title"
    }
}

/// A workspace currently shown on a monitor. `screenIndex` is 1-based into NSScreen.screens.
struct AeroVisible: Decodable, Equatable {
    let workspace: String
    let screenIndex: Int

    enum CodingKeys: String, CodingKey {
        case workspace
        case screenIndex = "monitor-appkit-nsscreen-screens-id"
    }
}

/// Thin wrapper around the `aerospace` CLI.
enum AeroSpace {
    static let path: String = {
        let candidates = ["/opt/homebrew/bin/aerospace", "/usr/local/bin/aerospace"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0]
    }()

    @discardableResult
    static func run(_ args: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    static func windows() -> [AeroWindow] {
        let format = "%{window-id}%{workspace}%{app-name}%{app-bundle-id}%{window-title}"
        guard let data = run(["list-windows", "--all", "--json", "--format", format]) else { return [] }
        return (try? JSONDecoder().decode([AeroWindow].self, from: data)) ?? []
    }

    /// Every workspace AeroSpace knows, including empty ones (here: 1–20 from the monitor assignment).
    static func allWorkspaces() -> [String] {
        guard let data = run(["list-workspaces", "--all"]) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    static func visible() -> [AeroVisible] {
        let format = "%{workspace}%{monitor-appkit-nsscreen-screens-id}"
        guard let data = run(["list-workspaces", "--monitor", "all", "--visible", "--json", "--format", format]) else { return [] }
        return (try? JSONDecoder().decode([AeroVisible].self, from: data)) ?? []
    }

    /// Workspace → 1-based index into NSScreen.screens of the monitor it belongs to.
    static func workspaceScreens() -> [String: Int] {
        let format = "%{workspace}%{monitor-appkit-nsscreen-screens-id}"
        guard let data = run(["list-workspaces", "--all", "--json", "--format", format]),
              let list = try? JSONDecoder().decode([AeroVisible].self, from: data) else { return [:] }
        return Dictionary(list.map { ($0.workspace, $0.screenIndex) }, uniquingKeysWith: { a, _ in a })
    }

    static func focused() -> String? {
        guard let data = run(["list-workspaces", "--focused"]) else { return nil }
        let name = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Binding mode → key ("alt-shift-h") → command ("move left"), read from the running config.
    /// Multi-command bindings come joined by "; ".
    static func bindings() -> [String: [String: String]] {
        struct Mode: Decodable { let binding: [String: String] }
        guard let data = run(["config", "--get", "mode", "--json"]),
              let modes = try? JSONDecoder().decode([String: Mode].self, from: data) else { return [:] }
        return modes.mapValues(\.binding)
    }

    static func configPath() -> String? {
        guard let data = run(["config", "--config-path"]) else { return nil }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    static func switchTo(_ workspace: String) {
        run(["workspace", workspace])
    }

    /// Focuses a window, switching to its workspace.
    static func focus(windowId: Int) {
        run(["focus", "--window-id", String(windowId)])
    }

    /// Numbers first (1, 2, … 20), then named workspaces alphabetically.
    static func order(_ a: String, _ b: String) -> Bool {
        switch (Int(a), Int(b)) {
        case let (x?, y?): return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return a < b
        }
    }
}
