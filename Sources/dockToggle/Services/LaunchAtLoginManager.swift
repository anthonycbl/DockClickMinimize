import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginManager {
    func apply(enabled: Bool) {
        guard #available(macOS 13.0, *) else {
            return
        }

        // SMAppService.mainApp requires a bundled app target.
        // `swift run` executes a plain binary, where register/unregister returns Invalid argument.
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.bundleIdentifier != nil else {
            return
        }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("DockClickMinimize launch-at-login update failed: \(error.localizedDescription)")
        }
    }
}
