import Foundation

enum IdleTimeout {
    static let choices: [TimeInterval] = [60, 120, 300, 600]
    static let fallbackTimeout: TimeInterval = 300
    static let fallbackGrace: TimeInterval = 120

    private static let timeoutKey = "idleTimeoutSeconds"
    private static let graceKey = "idleGraceSeconds"
    private static let notifyKey = "idleNotify"
    private static let defaults = UserDefaults(suiteName: "mactivity") ?? .standard

    static var timeout: TimeInterval {
        stored(timeoutKey, fallback: fallbackTimeout)
    }

    static var grace: TimeInterval {
        min(stored(graceKey, fallback: fallbackGrace), timeout)
    }

    static var notify: Bool {
        defaults.bool(forKey: notifyKey)
    }

    static func selectTimeout(_ seconds: TimeInterval) {
        guard choices.contains(seconds) else { return }
        defaults.set(Int(seconds), forKey: timeoutKey)
        if stored(graceKey, fallback: fallbackGrace) > seconds {
            defaults.set(Int(seconds), forKey: graceKey)
        }
    }

    static func selectGrace(_ seconds: TimeInterval) {
        guard choices.contains(seconds), seconds <= timeout else { return }
        defaults.set(Int(seconds), forKey: graceKey)
    }

    static func setNotify(_ enabled: Bool) {
        defaults.set(enabled, forKey: notifyKey)
    }

    private static func stored(_ key: String, fallback: TimeInterval) -> TimeInterval {
        let stored = defaults.integer(forKey: key)
        guard choices.contains(TimeInterval(stored)) else { return fallback }
        return TimeInterval(stored)
    }
}
