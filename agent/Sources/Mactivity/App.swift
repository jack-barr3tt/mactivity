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
    private var daemon: Process?
    private var daemonStartFailed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        startDaemon()
        IdleNotifier.install()
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
        if daemonStartFailed {
            statusDetail = "Could not start mactivityd"
        }
        rebuildMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate()
        recorder?.stop()
        recorder = nil
        stopDaemon()
    }

    private func startDaemon() {
        guard let executable = Bundle.main.executableURL else { return }
        let url = executable.deletingLastPathComponent().appendingPathComponent("mactivityd")
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return }
        let process = Process()
        process.executableURL = url
        do {
            try process.run()
            daemon = process
        } catch {
            daemonStartFailed = true
        }
    }

    private func stopDaemon() {
        guard let daemon, daemon.isRunning else {
            self.daemon = nil
            return
        }
        daemon.terminate()
        daemon.waitUntilExit()
        self.daemon = nil
    }

    private func pollPermission() {
        guard Probe.accessibilityTrusted(prompt: false) else { return }
        permissionTimer?.invalidate()
        permissionTimer = nil
        startRecording()
        if daemonStartFailed {
            statusDetail = "Could not start mactivityd"
        }
        rebuildMenu()
    }

    private func startRecording() {
        guard recorder == nil else { return }
        do {
            let store = try Store()
            let recorder = Recorder(store: store)
            recorder.onStatus = { [weak self] detail in
                guard let self, !self.daemonStartFailed, self.statusDetail != detail else { return }
                self.statusDetail = detail
                self.rebuildMenu()
            }
            statusDetail = "Recording"
            recorder.start()
            self.recorder = recorder
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
        menu.addItem(minutesItem(title: "Idle after", selected: IdleTimeout.timeout, action: #selector(selectTimeout(_:))))
        menu.addItem(minutesItem(
            title: "Count after activity",
            selected: IdleTimeout.grace,
            action: #selector(selectGrace(_:)),
            maxSeconds: IdleTimeout.timeout
        ))
        let notify = NSMenuItem(title: "Notify when idle", action: #selector(toggleNotify(_:)), keyEquivalent: "")
        notify.target = self
        notify.state = IdleTimeout.notify ? .on : .off
        menu.addItem(notify)
        let classify = NSMenuItem(title: "Classify windows", action: #selector(toggleClassify(_:)), keyEquivalent: "")
        classify.target = self
        classify.state = IdleTimeout.classify ? .on : .off
        menu.addItem(classify)
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

    private func minutesItem(
        title: String,
        selected: TimeInterval,
        action: Selector,
        maxSeconds: TimeInterval? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for seconds in IdleTimeout.choices {
            let minutes = Int(seconds / 60)
            let label = minutes == 1 ? "1 minute" : "\(minutes) minutes"
            let choice = NSMenuItem(title: label, action: action, keyEquivalent: "")
            choice.target = self
            choice.tag = Int(seconds)
            choice.state = selected == seconds ? .on : .off
            if let maxSeconds, seconds > maxSeconds {
                choice.isEnabled = false
            }
            submenu.addItem(choice)
        }
        item.submenu = submenu
        return item
    }

    @objc private func selectTimeout(_ sender: NSMenuItem) {
        IdleTimeout.selectTimeout(TimeInterval(sender.tag))
        rebuildMenu()
    }

    @objc private func selectGrace(_ sender: NSMenuItem) {
        IdleTimeout.selectGrace(TimeInterval(sender.tag))
        rebuildMenu()
    }

    @objc private func toggleClassify(_ sender: NSMenuItem) {
        let enabled = !IdleTimeout.classify
        IdleTimeout.setClassify(enabled)
        recorder?.setClassification(enabled: enabled)
        rebuildMenu()
    }

    @objc private func toggleNotify(_ sender: NSMenuItem) {
        if IdleTimeout.notify {
            IdleTimeout.setNotify(false)
            rebuildMenu()
            return
        }
        IdleNotifier.requestAccess { [weak self] granted in
            IdleTimeout.setNotify(granted)
            self?.rebuildMenu()
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
