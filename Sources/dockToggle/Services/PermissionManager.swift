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

    func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func hasInputMonitoringPermission() -> Bool {
        let mask = CGEventMask(1) << CGEventType.leftMouseDown.rawValue
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, _ in
                Unmanaged.passUnretained(event)
            },
            userInfo: nil
        )

        guard let tap else {
            return false
        }

        CFMachPortInvalidate(tap)
        return true
    }
}
