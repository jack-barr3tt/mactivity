import AppKit
import ApplicationServices

final class Recorder: @unchecked Sendable {
    var onStatus: ((String) -> Void)?

    private let store: Store
    private let classifier: any WindowClassifying
    private var timer: Timer?
    private var sampleState = SampleState()
    private var workspaceObserver: NSObjectProtocol?
    private var observer: AXObserver?
    private var watchedPID: pid_t = -1
    private var axRefcon: UnsafeMutableRawPointer?
    private var openID: Int64?
    private var openSnapshot: Snapshot?
    private var busy = false
    private var queue: [(id: Int64, snapshot: Snapshot)] = []

    init(store: Store, classifier: any WindowClassifying = AppleWindowClassifier()) {
        self.store = store
        self.classifier = classifier
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
        if let end = sampleState.pendingEnd {
            let ms = Int64((end.timeIntervalSince1970 * 1000).rounded())
            try? store.endOpen(at: ms)
            IdleNotifier.withdraw()
        } else {
            store.stop()
        }
        openID = nil
        openSnapshot = nil
        queue.removeAll()
        sampleState = SampleState()
    }

    func setClassification(enabled: Bool) {
        if enabled {
            classifyOpen()
        } else {
            queue.removeAll()
            publish(nil)
        }
    }

    func sample() {
        guard let observation = Probe.observe() else { return }
        watch(pid: observation.pid)
        let timeout = IdleTimeout.timeout
        let idle = Probe.idleSeconds() ?? 0
        let video = idle >= timeout && Probe.focusedVideoPlaying(bundleID: observation.snapshot.bundleID)
        let wasPending = sampleState.pendingEnd != nil
        let (next, action) = SamplePolicy.step(
            state: sampleState,
            input: SampleInput(
                snapshot: observation.snapshot,
                now: Date(),
                idle: idle,
                video: video,
                timeout: timeout,
                grace: IdleTimeout.grace,
                undoWindow: IdleNotifier.canUndo ? IdleNotifier.undoWindow : nil
            )
        )
        do {
            try apply(action, snapshot: observation.snapshot)
            if wasPending && next.pendingEnd == nil {
                IdleNotifier.withdraw()
            }
            sampleState = next
        } catch {
            FileHandle.standardError.write(Data("mactivity: \(error)\n".utf8))
        }
    }

    private func apply(_ action: SampleAction, snapshot: Snapshot) throws {
        switch action {
        case .none:
            return
        case .record:
            guard let written = try store.record(snapshot, reuseLabel: IdleTimeout.classify) else { return }
            log(snapshot)
            openID = written.id
            openSnapshot = snapshot
            if let label = written.label {
                publish(label)
            } else {
                publish(nil)
                enqueue(id: written.id, snapshot: snapshot)
            }
        case .end(let date):
            let ms = Int64((date.timeIntervalSince1970 * 1000).rounded())
            try store.endOpen(at: ms)
            openID = nil
            openSnapshot = nil
            publish(nil)
        case .notifyIdle:
            IdleNotifier.post()
        }
    }

    private func classifyOpen() {
        guard let id = openID, let snapshot = openSnapshot else { return }
        if let label = try? store.applyCachedLabel(id: id, snapshot: snapshot) {
            publish(label)
            return
        }
        enqueue(id: id, snapshot: snapshot)
    }

    private func enqueue(id: Int64, snapshot: Snapshot) {
        guard IdleTimeout.classify else { return }
        queue.append((id, snapshot))
        drain()
    }

    private func drain() {
        while !busy {
            guard !queue.isEmpty else { return }
            let item = queue.removeFirst()
            let needs: Bool
            do {
                needs = try store.needsLabel(id: item.id)
            } catch {
                logError(error)
                continue
            }
            guard needs else { continue }
            busy = true
            let classifier = classifier
            Task { [weak self] in
                do {
                    let label = try await classifier.classify(item.snapshot)
                    DispatchQueue.main.async {
                        self?.finishClassification(id: item.id, label: label)
                    }
                } catch {
                    DispatchQueue.main.async {
                        self?.logError(error)
                        self?.finishClassification(id: item.id, label: nil)
                    }
                }
            }
        }
    }

    private func finishClassification(id: Int64, label: WindowLabel?) {
        defer {
            busy = false
            if IdleTimeout.classify {
                drain()
            }
        }
        guard IdleTimeout.classify, let label else { return }
        do {
            try store.setLabel(id: id, label)
        } catch {
            logError(error)
            return
        }
        if openID == id {
            publish(label)
        }
    }

    private func publish(_ label: WindowLabel?) {
        onStatus?(label?.statusDetail ?? "Recording")
    }

    private func logError(_ error: Error) {
        let line = "mactivity: classify: \(error)\n"
        FileHandle.standardError.write(Data(line.utf8))
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
