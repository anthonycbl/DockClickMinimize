import AppKit
import Foundation

struct RuntimeSnapshot {
    var enabled: Bool
    var permissions: PermissionStatus
    var preferences: AppPreferences
}

final class DockClickCoordinator {
    private let windowController: WindowController
    private let lock = NSLock()
    private let isDebugLoggingEnabled = ProcessInfo.processInfo.environment["DOCKCLICK_DEBUG"] == "1"

    private var snapshot: RuntimeSnapshot

    init(windowController: WindowController, initialSnapshot: RuntimeSnapshot) {
        self.windowController = windowController
        snapshot = initialSnapshot
    }

    func update(snapshot: RuntimeSnapshot) {
        lock.lock()
        self.snapshot = snapshot
        lock.unlock()
    }

    func handle(_ resolution: DockClickResolution) -> DockClickHandling {
        let current = currentSnapshot()

        guard current.enabled else {
            return .passThrough
        }

        guard current.permissions.isOperational else {
            return .passThrough
        }

        guard let bundleID = resolution.app.bundleIdentifier else {
            return .passThrough
        }

        guard !current.preferences.excludedBundleIdentifiers.contains(bundleID) else {
            return .passThrough
        }

        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let isFrontmost = (frontmostPID == resolution.app.processIdentifier) || resolution.app.isActive

        if isFrontmost {
            debugLog("Treating click as frontmost for \(bundleID)")
            let app = resolution.app
            let preferences = current.preferences
            let controller = windowController
            DispatchQueue.main.async {
                Task { @MainActor in
                    await controller.handleFrontmostClick(app: app, preferences: preferences)
                }
            }
            return .consume
        }

        switch current.preferences.nonFrontmostClickBehavior {
        case .bringToFront:
            // Preserve native Dock behavior for background apps in bring-to-front mode.
            debugLog("Passing through non-frontmost click for \(bundleID)")
            return .passThrough
        case .minimizeImmediately:
            let app = resolution.app
            let controller = windowController
            let preferences = current.preferences
            DispatchQueue.main.async {
                Task { @MainActor in
                    let didMinimize = controller.minimizeImmediately(app: app)
                    if !didMinimize {
                        _ = app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                        try? await Task.sleep(for: .milliseconds(120))
                        await controller.handleFrontmostClick(app: app, preferences: preferences)
                    }
                }
            }
            debugLog("Consuming non-frontmost click for immediate minimize: \(bundleID)")
            return .consume
        }
    }

    private func currentSnapshot() -> RuntimeSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    private func debugLog(_ message: String) {
        guard isDebugLoggingEnabled else {
            return
        }
        NSLog("DockClickMinimize coordinator: \(message)")
    }
}
