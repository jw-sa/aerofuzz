import AppKit
import Carbon

/// Global hotkey via Carbon — needs no Accessibility permission.
final class HotKey {
    private static var handler: (() -> Void)?
    private var ref: EventHotKeyRef?

    init(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        HotKey.handler = handler
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            HotKey.handler?()
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4146_5A5A), id: 1)  // "AFZZ"
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let snapshots = SnapshotStore()
    private var panel: PanelController!
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem?
    private var signalSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = PanelController(snapshots: snapshots)

        // ⌥A toggles the panel.
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey)) { [weak self] in
            self?.panel.toggle()
        }

        // `pkill -USR1 AeroFuzz` also toggles, e.g. from an AeroSpace binding.
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in self?.panel.toggle() }
        source.resume()
        signalSource = source

        setUpStatusItem()

        if !snapshots.hasPermission { CGRequestScreenCaptureAccess() }
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "◫"
        let menu = NSMenu()
        menu.addItem(withTitle: "Show workspaces  (⌥A)", action: #selector(showPanel), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Screen Recording settings…", action: #selector(openScreenRecordingSettings), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit AeroFuzz", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func showPanel() { panel.show() }

    @objc private func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
