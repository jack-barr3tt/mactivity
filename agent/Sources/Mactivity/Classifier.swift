import Foundation
import FoundationModels

struct WindowLabel: Equatable {
    var category: String
    var workRelated: Bool
}

protocol WindowClassifying {
    func classify(_ snapshot: Snapshot) async throws -> WindowLabel?
}

@Generable
struct WindowClass {
    @Guide(
        description: "How this window is being used",
        .anyOf(WindowLabel.categories)
    )
    var category: String

    @Guide(description: "True when the window looks like paid or professional work")
    var workRelated: Bool
}

final class AppleWindowClassifier: WindowClassifying {
    private var loggedUnavailable = false

    func classify(_ snapshot: Snapshot) async throws -> WindowLabel? {
        let model = SystemLanguageModel.default
        guard model.availability == .available else {
            if !loggedUnavailable {
                loggedUnavailable = true
                FileHandle.standardError.write(Data("mactivity: on-device model unavailable\n".utf8))
            }
            return nil
        }
        let session = LanguageModelSession(model: model, instructions: Self.instructions)
        let response = try await session.respond(to: Self.prompt(snapshot), generating: WindowClass.self)
        let category = response.content.category
        guard WindowLabel.categories.contains(category) else { return nil }
        return WindowLabel(category: category, workRelated: response.content.workRelated)
    }

    private static let instructions = """
    Classify the focused window from the fields given. \
    category is how the person is spending this time. \
    workRelated is true for paid or professional work.
    """

    static func prompt(_ snapshot: Snapshot) -> String {
        """
        App: \(snapshot.appName)
        Bundle: \(snapshot.bundleID)
        Title: \(clip(snapshot.windowTitle))
        URL: \(clip(snapshot.url))
        Host: \(snapshot.hostname ?? "")
        """
    }

    private static func clip(_ value: String?) -> String {
        guard let value else { return "" }
        if value.count <= 500 {
            return value
        }
        return String(value.prefix(500))
    }
}

extension WindowLabel {
    static let categories = ["code", "communication", "docs", "browse", "media", "other"]

    var statusDetail: String {
        let work = workRelated ? "work" : "not work"
        return "Recording · \(category), \(work)"
    }
}
