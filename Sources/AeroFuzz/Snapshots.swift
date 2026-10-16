import AppKit
import ScreenCaptureKit
import os

let log = Logger(subsystem: "dk.juw.aerofuzz", category: "snapshots")

/// Builds a thumbnail per workspace from captures of its individual windows, in memory only
/// (they contain mail, chats, …). Runs only when the panel opens — no background work.
///
/// AeroSpace hides inactive workspaces by parking their windows in a screen corner, but
/// ScreenCaptureKit can still capture a single window wherever it is. The parking loses the
/// window's position (not its size), so positions are remembered whenever a workspace is visible;
/// windows never seen in place are laid out side by side.
final class SnapshotStore {
    private(set) var images: [String: NSImage] = [:]
    /// Window id → frame normalised to its display (0…1, top-left origin), from when it was visible.
    private var layout: [Int: CGRect] = [:]
    private var running = false
    private static let thumbnailWidth: CGFloat = 800

    var onUpdate: ((String) -> Void)?

    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    func refresh(windows: [AeroWindow], visible: Set<String>) {
        guard !running else { return }
        guard hasPermission else { log.error("no Screen Recording permission"); return }

        // Which display each workspace lives on, in CoreGraphics (top-left) coordinates.
        var displayBounds: [String: CGRect] = [:]
        for (workspace, screenIndex) in AeroSpace.workspaceScreens() {
            if let id = Self.displayID(screenIndex: screenIndex) { displayBounds[workspace] = CGDisplayBounds(id) }
        }
        let byWorkspace = Dictionary(grouping: windows, by: \.workspace)
        for workspace in images.keys where byWorkspace[workspace] == nil { images[workspace] = nil }

        let known = layout
        running = true
        Task {
            var learned: [Int: CGRect] = [:]
            defer {
                Task { @MainActor in
                    self.layout.merge(learned) { _, new in new }
                    self.running = false
                }
            }
            let content: SCShareableContent
            do { content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) }
            catch { log.error("shareable content failed: \(error.localizedDescription, privacy: .public)"); return }
            let scWindows = Dictionary(content.windows.map { (Int($0.windowID), $0) }, uniquingKeysWith: { a, _ in a })

            // Visible workspaces first: they are what you just looked at.
            let order = byWorkspace.keys.sorted { visible.contains($0) && !visible.contains($1) }
            for workspace in order {
                guard let bounds = displayBounds[workspace], let members = byWorkspace[workspace] else { continue }
                let found = members.compactMap { scWindows[$0.windowId] }
                if visible.contains(workspace) {
                    for window in found { learned[Int(window.windowID)] = Self.normalise(window.frame, in: bounds) }
                }
                let rects = Self.placement(for: found, in: bounds) { learned[$0] ?? known[$0] }

                var pieces: [(CGRect, CGImage)] = []
                for window in found {
                    guard let rect = rects[Int(window.windowID)] else { continue }
                    if let image = await Self.capture(window, width: rect.width * Self.thumbnailWidth) {
                        pieces.append((rect, image))
                    }
                }
                guard let composed = Self.compose(pieces, aspect: bounds.height / bounds.width) else { continue }
                // `defaults write dk.juw.aerofuzz dumpSnapshots -bool true` → /tmp/aerofuzz-snapshots/ for debugging.
                if UserDefaults.standard.bool(forKey: "dumpSnapshots") { Self.dump(composed, name: workspace) }
                await MainActor.run {
                    self.images[workspace] = NSImage(cgImage: composed, size: .zero)
                    self.onUpdate?(workspace)
                }
            }
        }
    }

    // MARK: - Helpers

    private static func capture(_ window: SCWindow, width: CGFloat) async -> CGImage? {
        let config = SCStreamConfiguration()
        let scale = min(1, max(width, 40) / max(window.frame.width, 1))
        config.width = max(Int(window.frame.width * scale), 1)
        config.height = max(Int(window.frame.height * scale), 1)
        config.showsCursor = false
        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
        } catch {
            log.error("capture of window \(window.windowID) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Remembered positions where we have them; the rest side by side using their real sizes
    /// (AeroSpace keeps tiled sizes while hiding), or equal columns if those don't add up.
    private static func placement(for windows: [SCWindow], in bounds: CGRect,
                                  remembered: (Int) -> CGRect?) -> [Int: CGRect] {
        var rects: [Int: CGRect] = [:]
        var unknown: [SCWindow] = []
        for window in windows {
            if let rect = remembered(Int(window.windowID)) { rects[Int(window.windowID)] = rect } else { unknown.append(window) }
        }
        guard !unknown.isEmpty else { return rects }
        let widths = unknown.map { min(1, $0.frame.width / bounds.width) }
        let useRealWidths = widths.reduce(0, +) <= 1.05
        var x: CGFloat = 0
        for (index, window) in unknown.enumerated() {
            let width = useRealWidths ? widths[index] : 1 / CGFloat(unknown.count)
            let height = min(1, window.frame.height / bounds.height)
            rects[Int(window.windowID)] = CGRect(x: x, y: 1 - height, width: width, height: height)
            x += width
        }
        return rects
    }

    private static func normalise(_ frame: CGRect, in bounds: CGRect) -> CGRect {
        CGRect(x: (frame.minX - bounds.minX) / bounds.width, y: (frame.minY - bounds.minY) / bounds.height,
               width: frame.width / bounds.width, height: frame.height / bounds.height)
    }

    /// Draws the window captures onto a dark canvas shaped like the display; big windows first
    /// so small floating ones (palettes, dialogs) end up on top.
    private static func compose(_ pieces: [(CGRect, CGImage)], aspect: CGFloat) -> CGImage? {
        guard !pieces.isEmpty else { return nil }
        let width = Int(thumbnailWidth)
        let height = Int(thumbnailWidth * aspect)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0.08, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        let w = CGFloat(width), h = CGFloat(height)
        for (rect, image) in pieces.sorted(by: { $0.0.width * $0.0.height > $1.0.width * $1.0.height }) {
            // Normalised rects are top-left based; CGContext is bottom-left.
            let slot = CGRect(x: rect.minX * w, y: (1 - rect.maxY) * h, width: rect.width * w, height: rect.height * h)
            context.draw(image, in: aspectFit(image, in: slot))
        }
        return context.makeImage()
    }

    /// Keeps the window's proportions inside its slot (guessed slots rarely match), top-aligned.
    private static func aspectFit(_ image: CGImage, in slot: CGRect) -> CGRect {
        let scale = min(slot.width / CGFloat(image.width), slot.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(x: slot.midX - size.width / 2, y: slot.maxY - size.height, width: size.width, height: size.height)
    }

    private static func dump(_ image: CGImage, name: String) {
        let dir = URL(fileURLWithPath: "/tmp/aerofuzz-snapshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        try? data?.write(to: dir.appendingPathComponent("ws\(name).png"))
    }

    private static func displayID(screenIndex: Int) -> CGDirectDisplayID? {
        let screens = NSScreen.screens
        guard screenIndex >= 1, screenIndex <= screens.count else { return nil }
        let number = screens[screenIndex - 1].deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number?.uint32Value
    }
}
