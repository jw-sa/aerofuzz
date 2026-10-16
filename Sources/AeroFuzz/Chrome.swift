import AppKit

struct ChromeTab {
    let windowId: String     // Chrome's own AppleScript window id, not AeroSpace's
    let windowName: String   // = title of the window's active tab
    let index: Int           // 1-based
    let title: String
    let url: String

    var host: String { URL(string: url)?.host ?? url }
}

/// Reads and activates Chrome tabs over AppleScript (first use asks for Automation permission).
enum Chrome {
    static let bundleId = "com.google.Chrome"

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }

    private static let unit = "\u{1F}"
    private static let record = "\u{1E}"

    /// Slow-ish (tens of ms per window) and may block on the permission prompt: call off the main thread.
    static func tabs() -> [ChromeTab] {
        let script = """
        set US to character id 31
        set RS to character id 30
        set out to ""
        tell application id "\(bundleId)"
            repeat with w in windows
                set wid to (id of w) as text
                set wname to name of w
                set titles to title of tabs of w
                set urls to URL of tabs of w
                repeat with i from 1 to count of titles
                    set out to out & wid & US & wname & US & i & US & (item i of titles) & US & (item i of urls) & RS
                end repeat
            end repeat
        end tell
        return out
        """
        guard let output = osascript(script) else { return [] }
        return output.components(separatedBy: record).compactMap { line in
            let f = line.components(separatedBy: unit)
            guard f.count == 5, let index = Int(f[2]) else { return nil }
            return ChromeTab(windowId: f[0], windowName: f[1], index: index, title: f[3], url: f[4])
        }
    }

    static func activate(_ tab: ChromeTab) {
        osascript("""
        tell application id "\(bundleId)" to set active tab index of (first window whose id is \(tab.windowId)) to \(tab.index)
        """)
    }

    @discardableResult
    private static func osascript(_ script: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
}
