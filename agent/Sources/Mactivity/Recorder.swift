import AppKit
import ApplicationServices

final class Recorder {
    private let store: Store
    private var timer: Timer?
    private var workspaceObserver: NSObjectProtocol?
    private var observer: AXObserver?
    private var watchedPID: pid_t = -1
    private var axRefcon: UnsafeMutableRawPointer?

    init(store: Store) {
        self.store = store
    }

    func start() {
        axRefcon = Unmanaged.passUnretained(self).toOpaque()
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.sample()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.sample()
        }
        sample()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
        clearObserver()
        store.stop()
    }

    func sample() {
        guard let observation = Probe.observe() else { return }
        watch(pid: observation.pid)
        do {
            if try store.record(observation.snapshot) {
                log(observation.snapshot)
            }
        } catch {
            FileHandle.standardError.write(Data("mactivity: \(error)\n".utf8))
        }
    }

    private func watch(pid: pid_t) {
        guard pid != watchedPID, let refcon = axRefcon else { return }
        clearObserver()
        var created: AXObserver?
        guard AXObserverCreate(pid, axCallback, &created) == .success, let created else { return }
        let app = AXUIElementCreateApplication(pid)
        let notes = [
            kAXFocusedWindowChangedNotification as String,
            kAXFocusedUIElementChangedNotification as String,
        ]
        for note in notes {
            AXObserverAddNotification(created, app, note as CFString, refcon)
        }
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(created),
            .commonModes
        )
        observer = created
        watchedPID = pid
    }

    private func clearObserver() {
        if let observer {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }
        observer = nil
        watchedPID = -1
    }

    private func log(_ snapshot: Snapshot) {
        let title = snapshot.windowTitle ?? ""
        let host = snapshot.hostname ?? ""
        let line = "mactivity: \(snapshot.appName) \(title) \(host)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

private func axCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let recorder = Unmanaged<Recorder>.fromOpaque(refcon).takeUnretainedValue()
    recorder.sample()
}
