import AppKit
import ApplicationServices

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
