import ApplicationServices
import AppKit
import Foundation

struct PermissionStatus: Equatable {
    var accessibilityGranted: Bool
    var inputMonitoringGranted: Bool

    var isOperational: Bool {
        accessibilityGranted && inputMonitoringGranted
    }
}

@MainActor
final class PermissionManager {
    func status() -> PermissionStatus {
        PermissionStatus(
            accessibilityGranted: AXIsProcessTrusted(),
            inputMonitoringGranted: hasInputMonitoringPermission()
        )
    }

    func requestAccessibilityPrompt() {
        let key = "AXTrustedCheckOptionPrompt"
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func requestInputMonitoringPrompt() {
        _ = CGRequestListenEventAccess()
    }

    func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    // CGPreflightListenEventAccess is the official Input Monitoring check;
    // probing by creating an event tap can report the wrong state when only
    // Accessibility is granted.
    private func hasInputMonitoringPermission() -> Bool {
        CGPreflightListenEventAccess()
    }
}
