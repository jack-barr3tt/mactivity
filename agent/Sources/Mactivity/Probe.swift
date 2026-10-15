import AppKit
import ApplicationServices
import CoreMediaIO
import IOKit

enum Probe {
    static let chromeBundleID = "com.google.Chrome"

    struct Observation {
        var pid: pid_t
        var snapshot: Snapshot
    }

    static func observe() -> Observation? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        let bundleID = app.bundleIdentifier ?? ""
        let appName = nonEmpty(app.localizedName) ?? (bundleID.isEmpty ? "Unknown" : bundleID)
        let title = focusedWindowTitle(pid: pid)
        var url: String?
        var hostname: String?
        if bundleID == chromeBundleID {
            url = chromeURL(pid: pid) ?? chromeURLViaAppleScript()
            hostname = url.flatMap(hostname(from:))
        }
        return Observation(
            pid: pid,
            snapshot: Snapshot(
                appName: appName,
                bundleID: bundleID,
                windowTitle: title,
                url: url,
                hostname: hostname
            )
        )
    }

    static func idleSeconds() -> TimeInterval? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        guard let property = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        let value = property.takeRetainedValue()
        guard let number = value as? NSNumber else { return nil }
        let nanos = number.int64Value
        guard nanos >= 0 else { return nil }
        return TimeInterval(nanos) / 1_000_000_000
    }

    static func idleHold(bundleID: String) -> IdleHold {
        var hold = IdleHold()
        if focusedVideoPlaying(bundleID: bundleID) {
            hold.insert(.focusedVideo)
        }
        if cameraInUse() {
            hold.insert(.camera)
        }
        return hold
    }

    static func focusedVideoPlaying(bundleID: String) -> Bool {
        switch bundleID {
        case chromeBundleID:
            return browserVideoPlaying(
                application: "Google Chrome",
                tab: "return execute javascript \"\(videoScript)\" in active tab of front window"
            )
        case "com.apple.Safari":
            return browserVideoPlaying(
                application: "Safari",
                tab: "return do JavaScript \"\(videoScript)\" in current tab of front window"
            )
        case "com.apple.QuickTimePlayerX":
            return scriptIsTrue("""
            tell application "QuickTime Player"
                if (count of documents) is 0 then return false
                return playing of front document
            end tell
            """)
        case "com.apple.TV":
            return scriptIsTrue("""
            tell application "TV" to return player state is playing
            """)
        case "com.colliderli.iina":
            return scriptIsTrue("""
            tell application "IINA" to return playing
            """)
        case "org.videolan.vlc":
            return scriptIsTrue("""
            tell application "VLC" to return playing
            """)
        default:
            return false
        }
    }

    private static func cameraInUse() -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return false
        }
        let count = Int(dataSize) / MemoryLayout<CMIODeviceID>.size
        var devices = [CMIODeviceID](repeating: 0, count: count)
        var used: UInt32 = 0
        let status = devices.withUnsafeMutableBytes { raw in
            CMIOObjectGetPropertyData(system, &address, 0, nil, dataSize, &used, raw.baseAddress)
        }
        guard status == noErr else { return false }
        let listed = Int(used) / MemoryLayout<CMIODeviceID>.size
        return devices.prefix(listed).contains(where: deviceIsRunning)
    }

    private static func deviceIsRunning(_ device: CMIODeviceID) -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard)
        )
        var running: UInt32 = 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(device, &address, 0, nil, size, &used, &running)
        return status == noErr && running != 0
    }

    static func accessibilityTrusted(prompt: Bool) -> Bool {
        if !prompt {
            return AXIsProcessTrusted()
        }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private static func focusedWindowTitle(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        guard let window = copyElement(app, kAXFocusedWindowAttribute as String) else { return nil }
        return copyString(window, kAXTitleAttribute as String)
    }

    private static func chromeURL(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        if let window = copyElement(app, kAXFocusedWindowAttribute as String),
           let url = copyString(window, "AXURL") {
            return url
        }
        if let focused = copyElement(app, kAXFocusedUIElementAttribute as String),
           let url = copyString(focused, "AXURL") {
            return url
        }
        return nil
    }

    private static let videoScript =
        "(function(){var list=document.querySelectorAll('video');" +
        "for(var i=0;i<list.length;i++){var v=list[i];if(!v.paused&&!v.ended)return true;}return false;})()"

    private static func browserVideoPlaying(application: String, tab: String) -> Bool {
        let source = """
        tell application "\(application)"
            if (count of windows) is 0 then return false
            \(tab)
        end tell
        """
        return scriptIsTrue(source)
    }

    private static func scriptIsTrue(_ source: String) -> Bool {
        guard let descriptor = runScript(source) else { return false }
        if descriptor.booleanValue { return true }
        return descriptor.stringValue == "true"
    }

    private static func runScript(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let descriptor = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return descriptor
    }

    private static func chromeURLViaAppleScript() -> String? {
        let source = """
        tell application "Google Chrome"
            if (count of windows) is 0 then return ""
            return URL of active tab of front window
        end tell
        """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let descriptor = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return nonEmpty(descriptor.stringValue)
    }

    private static func hostname(from urlString: String) -> String? {
        guard let host = URL(string: urlString)?.host, !host.isEmpty else { return nil }
        return host.lowercased()
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else {
            return nil
        }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else {
            return nil
        }
        if let text = value as? String {
            return nonEmpty(text)
        }
        if let url = value as? URL {
            return nonEmpty(url.absoluteString)
        }
        return nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
