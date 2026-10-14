import AppKit
import Darwin

@main
enum Main {
    private static let delegate = AppDelegate()

    static func main() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var recorder: Recorder?
    private var permissionTimer: Timer?
    private var statusDetail = "Starting"
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(systemSymbolName: "clock", accessibilityDescription: "mactivity") {
            image.isTemplate = true
            statusItem?.button?.image = image
        }
        installSignalHandlers()
        if Probe.accessibilityTrusted(prompt: true) {
            startRecording()
        } else {
            statusDetail = "Grant Accessibility in System Settings"
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.pollPermission()
            }
        }
        rebuildMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate()
        recorder?.stop()
        recorder = nil
    }

    private func pollPermission() {
        guard Probe.accessibilityTrusted(prompt: false) else { return }
        permissionTimer?.invalidate()
        permissionTimer = nil
        startRecording()
        rebuildMenu()
    }

    private func startRecording() {
        guard recorder == nil else { return }
        do {
            let store = try Store()
            let recorder = Recorder(store: store)
            recorder.start()
            self.recorder = recorder
            statusDetail = "Recording"
        } catch {
            statusDetail = error.localizedDescription
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let status = NSMenuItem(title: statusDetail, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if recorder == nil {
            let grant = NSMenuItem(
                title: "Request Accessibility Permission",
                action: #selector(requestPermission),
                keyEquivalent: ""
            )
            grant.target = self
            menu.addItem(grant)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem?.menu = menu
        statusItem?.button?.toolTip = "mactivity — \(statusDetail)"
    }

    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM] {
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    @objc private func requestPermission() {
        _ = Probe.accessibilityTrusted(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
