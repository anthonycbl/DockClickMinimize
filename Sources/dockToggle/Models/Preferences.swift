import Foundation

enum FrontmostMinimizeBehavior: String, Codable, CaseIterable, Identifiable {
    case minimizeAllWindows
    case minimizeFrontmostWindow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .minimizeAllWindows:
            return "Minimize all windows"
        case .minimizeFrontmostWindow:
            return "Minimize frontmost window"
        }
    }
}

enum RestoreBehavior: String, Codable, CaseIterable, Identifiable {
    case restoreAllMinimizedWindows
    case restoreLastActiveWindow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .restoreAllMinimizedWindows:
            return "Restore all minimized windows"
        case .restoreLastActiveWindow:
            return "Restore last active window"
        }
    }
}

enum ModalBlockingBehavior: String, Codable, CaseIterable, Identifiable {
    case doNothing
    case minimizeMainWindowBehindModal
    case minimizeModalIfPossible

    var id: String { rawValue }

    var title: String {
        switch self {
        case .doNothing:
            return "Do nothing"
        case .minimizeMainWindowBehindModal:
            return "Minimize main window behind modal"
        case .minimizeModalIfPossible:
            return "Minimize modal if possible"
        }
    }
}

enum FullscreenBehavior: String, Codable, CaseIterable, Identifiable {
    case exitFullscreenThenMinimize
    case doNothing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .exitFullscreenThenMinimize:
            return "Exit fullscreen then minimize"
        case .doNothing:
            return "Do nothing"
        }
    }
}

enum NonFrontmostClickBehavior: String, Codable, CaseIterable, Identifiable {
    case bringToFront
    case minimizeImmediately

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bringToFront:
            return "Bring to front"
        case .minimizeImmediately:
            return "Minimize immediately"
        }
    }
}

struct AppPreferences: Codable, Equatable {
    var enabled: Bool
    var launchAtLogin: Bool

    var frontmostMinimizeBehavior: FrontmostMinimizeBehavior
    var restoreBehavior: RestoreBehavior
    var modalBlockingBehavior: ModalBlockingBehavior
    var fullscreenBehavior: FullscreenBehavior

    var nonFrontmostClickBehavior: NonFrontmostClickBehavior

    var excludedBundleIdentifiers: Set<String>

    static let `default` = AppPreferences(
        enabled: true,
        launchAtLogin: false,
        frontmostMinimizeBehavior: .minimizeAllWindows,
        restoreBehavior: .restoreAllMinimizedWindows,
        modalBlockingBehavior: .doNothing,
        fullscreenBehavior: .exitFullscreenThenMinimize,
        nonFrontmostClickBehavior: .bringToFront,
        excludedBundleIdentifiers: []
    )
}
