import ApplicationServices
import AppKit
import Foundation

// Diagnostic dump of an app's real AX window tree. Run via:
//   /Applications/DockClickMinimize.app/Contents/MacOS/DockClickMinimize --dump-finder
// Used to understand how Finder represents tabs before changing minimize/restore logic.
enum WindowDiagnostics {
    static func runAndExit(bundleID: String) -> Never {
        guard AXIsProcessTrusted() else {
            print("NOT TRUSTED: this binary does not have Accessibility permission when launched this way.")
            print("Grant it, or run the diagnostic from the installed app instead.")
            exit(2)
        }

        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            print("App \(bundleID) is not running. Open it (with a few tabs) and retry.")
            exit(1)
        }

        let pid = app.processIdentifier
        print("=== AX window dump for \(bundleID) (pid \(pid)) ===")

        let appElement = AXUIElementCreateApplication(pid)

        // Dump twice so we can see which attributes are stable across reads.
        for pass in 1...2 {
            print("\n--- pass \(pass) ---")
            dumpWindows(of: appElement)
        }

        exit(0)
    }

    private static func dumpWindows(of appElement: AXUIElement) {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let windows = value as? [AXUIElement] else {
            print("  (no windows; AXError \(result.rawValue))")
            return
        }

        print("  window count: \(windows.count)")
        for (index, window) in windows.enumerated() {
            let title = string(window, kAXTitleAttribute as String) ?? "<nil>"
            let subrole = string(window, kAXSubroleAttribute as String) ?? "<nil>"
            let minimized = bool(window, kAXMinimizedAttribute as String)
            let main = bool(window, kAXMainAttribute as String)
            let focused = bool(window, kAXFocusedAttribute as String)
            let windowNumber = raw(window, "AXWindowNumber")
            let pointer = UInt(bitPattern: Unmanaged.passUnretained(window).toOpaque())

            print("  [\(index)] title=\"\(title)\"")
            print("       subrole=\(subrole) minimized=\(describe(minimized)) main=\(describe(main)) focused=\(describe(focused))")
            print("       AXWindowNumber=\(windowNumber) elementPointer=0x\(String(pointer, radix: 16))")
        }
    }

    private static func describe(_ value: Bool?) -> String {
        value.map { "\($0)" } ?? "<nil>"
    }

    private static func raw(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value else {
            return "<unavailable AXError \(result.rawValue)>"
        }
        if let number = value as? NSNumber {
            return "\(number)"
        }
        return "\(value)"
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? Bool
    }
}
