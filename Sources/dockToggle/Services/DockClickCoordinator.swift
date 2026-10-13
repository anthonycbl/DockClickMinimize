import AppKit
import ApplicationServices
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
            // Only consume the click if the app actually has windows to act on;
            // otherwise pass through so native Dock behavior (e.g. reopening a
            // window) still works instead of the click doing nothing.
            guard appHasWindows(pid: resolution.app.processIdentifier) else {
                debugLog("Frontmost app has no windows; passing through for \(bundleID)")
                return .passThrough
            }

            debugLog("Treating click as frontmost for \(bundleID)")
            let app = resolution.app
            let preferences = current.preferences
            let controller = windowController
            Task { @MainActor in
                await controller.handleFrontmostClick(app: app, preferences: preferences)
            }
            return .consume
        }

        switch current.preferences.nonFrontmostClickBehavior {
        case .bringToFront:
            // If every window is minimized (usually because we minimized them),
            // handle the restore ourselves. Passing through would let the Dock's
            // native reopen pick an arbitrary window/tab (e.g. switching Finder tabs).
            if allWindowsMinimized(pid: resolution.app.processIdentifier) {
                debugLog("All windows minimized; restoring for \(bundleID)")
                let app = resolution.app
                let preferences = current.preferences
                let controller = windowController
                Task { @MainActor in
                    await controller.handleFrontmostClick(app: app, preferences: preferences)
                }
                return .consume
            }

            // Preserve native Dock behavior for background apps in bring-to-front mode.
            debugLog("Passing through non-frontmost click for \(bundleID)")
            return .passThrough
        case .minimizeImmediately:
            let app = resolution.app
            let controller = windowController
            let preferences = current.preferences
            Task { @MainActor in
                let didMinimize = controller.minimizeImmediately(app: app)
                if !didMinimize {
                    _ = app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                    try? await Task.sleep(for: .milliseconds(120))
                    await controller.handleFrontmostClick(app: app, preferences: preferences)
                }
            }
            debugLog("Consuming non-frontmost click for immediate minimize: \(bundleID)")
            return .consume
        }
    }

    private func appHasWindows(pid: pid_t) -> Bool {
        !windowElements(pid: pid).isEmpty
    }

    private func allWindowsMinimized(pid: pid_t) -> Bool {
        let windows = windowElements(pid: pid)
        guard !windows.isEmpty else {
            return false
        }

        for window in windows {
            var minimized: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success,
                  (minimized as? Bool) == true else {
                return false
            }
        }
        return true
    }

    private func windowElements(pid: pid_t) -> [AXUIElement] {
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else {
            return []
        }
        return windows
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
