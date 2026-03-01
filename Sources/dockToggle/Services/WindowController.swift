import ApplicationServices
import AppKit
import Foundation

private enum AXCustomAttribute {
    static let windowNumber = "AXWindowNumber"
    static let visible = "AXVisible"
    static let fullScreen = "AXFullScreen"
}

private struct RestoreLedger {
    let orderedWindowIDs: [Int]
    let lastActiveWindowID: Int?
    let createdAt: Date
}

private struct AXWindowInfo {
    let element: AXUIElement
    let windowID: Int
    let role: String?
    let subrole: String?
    let isMinimized: Bool?
    let isVisible: Bool?
    let isFullScreen: Bool?
    let isMain: Bool?
    let isFocused: Bool?
    let canSetMinimized: Bool?
    let canRaise: Bool

    var isStandardWindow: Bool {
        let roleLooksWindowLike = role == nil || role == kAXWindowRole as String
        return roleLooksWindowLike && subrole != kAXSystemDialogSubrole as String
    }

    var isActionableForMinimize: Bool {
        canSetMinimized != false
    }
}

@MainActor
final class WindowController {
    private var restoreLedgerByPID: [pid_t: RestoreLedger] = [:]
    private let isDebugLoggingEnabled = ProcessInfo.processInfo.environment["DOCKCLICK_DEBUG"] == "1"

    func handleFrontmostClick(app: NSRunningApplication, preferences: AppPreferences) async {
        let pid = app.processIdentifier
        let windows = standardWindows(for: pid)
        debugLog("Frontmost click for \(app.bundleIdentifier ?? "?"), windows=\(windows.count)")

        guard !windows.isEmpty else {
            return
        }

        let frontWindow = pickFrontWindow(from: windows)
        let modalAssessment = assessModalBlocking(windows: windows, mainWindow: frontWindow)

        if SafetyDecisions.shouldNoOpForModal(modalAssessment, behavior: preferences.modalBlockingBehavior) {
            return
        }

        if modalAssessment == .blocked {
            handleBlockedModal(windows: windows, mainWindow: frontWindow, behavior: preferences.modalBlockingBehavior)
            return
        }

        if shouldRestore(pid: pid, windows: windows, behavior: preferences.restoreBehavior) {
            restoreWindows(pid: pid, windows: windows, behavior: preferences.restoreBehavior)
            return
        }

        guard let frontWindow else {
            return
        }

        if frontWindow.isFullScreen == true {
            switch preferences.fullscreenBehavior {
            case .doNothing:
                return
            case .exitFullscreenThenMinimize:
                let exited = await exitFullscreen(window: frontWindow, timeoutSeconds: 2.0)
                guard exited else {
                    return
                }
            }
        }

        let targets = minimizeTargets(from: windows, frontWindow: frontWindow, behavior: preferences.frontmostMinimizeBehavior)
        let minimizedIDs = minimize(windows: targets)
        debugLog("Minimize targets=\(targets.count), minimized=\(minimizedIDs.count)")

        guard !minimizedIDs.isEmpty else {
            return
        }

        restoreLedgerByPID[pid] = RestoreLedger(
            orderedWindowIDs: minimizedIDs,
            lastActiveWindowID: frontWindow.windowID,
            createdAt: Date()
        )
    }

    func minimizeImmediately(app: NSRunningApplication) -> Bool {
        let windows = standardWindows(for: app.processIdentifier)
        let minimizableWindows = windows.filter { info in
            info.isMinimized != true && info.isActionableForMinimize
        }

        let minimized = minimize(windows: minimizableWindows)
        var didHide = false
        var didActivateForFallback = false

        if minimized.isEmpty {
            didHide = app.hide()

            if !didHide {
                didActivateForFallback = app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                didHide = app.hide() || didHide
            }
        }
        let didSucceed = !minimized.isEmpty || didHide
        debugLog(
            "Immediate minimize for \(app.bundleIdentifier ?? "?"), " +
            "candidates=\(minimizableWindows.count), minimized=\(minimized.count), " +
            "didHide=\(didHide), didActivateFallback=\(didActivateForFallback)"
        )
        return didSucceed
    }

    private func shouldRestore(pid: pid_t, windows: [AXWindowInfo], behavior: RestoreBehavior) -> Bool {
        let minimizable = windows.filter { $0.isActionableForMinimize }
        let currentlyMinimized = minimizable.filter { $0.isMinimized == true }
        let currentlyUnminimized = minimizable.filter { $0.isMinimized != true }
        let ledgerMinimizationStates: [Bool] = {
            guard let ledger = restoreLedgerByPID[pid], !ledger.orderedWindowIDs.isEmpty else {
                return []
            }

            let windowByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) })
            return ledger.orderedWindowIDs.map { windowByID[$0]?.isMinimized == true }
        }()

        return RestoreDecision.shouldRestore(
            behavior: behavior,
            minimizedCount: currentlyMinimized.count,
            unminimizedCount: currentlyUnminimized.count,
            ledgerMinimizationStates: ledgerMinimizationStates
        )
    }

    private func restoreWindows(pid: pid_t, windows: [AXWindowInfo], behavior: RestoreBehavior) {
        let minimizedNow = windows.filter { $0.isActionableForMinimize && $0.isMinimized == true }
        guard !minimizedNow.isEmpty else {
            restoreLedgerByPID[pid] = nil
            return
        }

        let targets: [AXWindowInfo]
        switch behavior {
        case .restoreAllMinimizedWindows:
            // Always restore all currently minimized windows for restore-all mode.
            targets = minimizedNow
        case .restoreLastActiveWindow:
            if let ledger = restoreLedgerByPID[pid] {
                let windowByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) })
                let candidateIDs = RestorePlanner.windowsToRestore(
                    orderedWindowIDs: ledger.orderedWindowIDs,
                    lastActiveWindowID: ledger.lastActiveWindowID,
                    behavior: behavior
                )

                let ledgerTargets = candidateIDs.compactMap { windowByID[$0] }.filter { $0.isMinimized == true }
                if !ledgerTargets.isEmpty {
                    targets = ledgerTargets
                } else {
                    targets = fallbackRestoreTargets(from: minimizedNow, behavior: behavior)
                }
            } else {
                targets = fallbackRestoreTargets(from: minimizedNow, behavior: behavior)
            }
        }

        guard !targets.isEmpty else {
            restoreLedgerByPID[pid] = nil
            return
        }

        for target in targets where target.isActionableForMinimize {
            _ = setBoolAttribute(kAXMinimizedAttribute as String, value: false, on: target.element)
        }
        debugLog("Restore targets=\(targets.count)")

        if let first = targets.first, first.canRaise {
            _ = AXUIElementPerformAction(first.element, kAXRaiseAction as CFString)
        }

        restoreLedgerByPID[pid] = nil
    }

    private func fallbackRestoreTargets(from minimizedWindows: [AXWindowInfo], behavior: RestoreBehavior) -> [AXWindowInfo] {
        switch behavior {
        case .restoreAllMinimizedWindows:
            return minimizedWindows
        case .restoreLastActiveWindow:
            return minimizedWindows.first.map { [$0] } ?? []
        }
    }

    private func minimizeTargets(from windows: [AXWindowInfo], frontWindow: AXWindowInfo, behavior: FrontmostMinimizeBehavior) -> [AXWindowInfo] {
        let minimizable = windows.filter { info in
            info.isMinimized != true && info.isActionableForMinimize
        }

        switch behavior {
        case .minimizeAllWindows:
            let sorted = minimizable.sorted { lhs, rhs in
                if lhs.windowID == frontWindow.windowID { return true }
                if rhs.windowID == frontWindow.windowID { return false }
                return lhs.windowID < rhs.windowID
            }
            return sorted
        case .minimizeFrontmostWindow:
            guard minimizable.contains(where: { $0.windowID == frontWindow.windowID }) else {
                return []
            }
            return [frontWindow]
        }
    }

    private func minimize(windows: [AXWindowInfo]) -> [Int] {
        var minimized: [Int] = []

        for window in windows where window.isActionableForMinimize {
            let didSet = setBoolAttribute(kAXMinimizedAttribute as String, value: true, on: window.element)
            if didSet {
                minimized.append(window.windowID)
            }
        }

        return minimized
    }

    private func handleBlockedModal(windows: [AXWindowInfo], mainWindow: AXWindowInfo?, behavior: ModalBlockingBehavior) {
        switch behavior {
        case .doNothing:
            return
        case .minimizeMainWindowBehindModal:
            guard let mainWindow, mainWindow.isActionableForMinimize else {
                return
            }
            _ = setBoolAttribute(kAXMinimizedAttribute as String, value: true, on: mainWindow.element)
        case .minimizeModalIfPossible:
            guard let modal = windows.first(where: {
                ($0.subrole == kAXDialogSubrole as String || $0.subrole == kAXSystemDialogSubrole as String) &&
                $0.isActionableForMinimize
            }) else {
                return
            }
            _ = setBoolAttribute(kAXMinimizedAttribute as String, value: true, on: modal.element)
        }
    }

    private func assessModalBlocking(windows: [AXWindowInfo], mainWindow: AXWindowInfo?) -> ModalBlockAssessment {
        let hasModalWindow = windows.contains {
            ($0.subrole == kAXDialogSubrole as String || $0.subrole == kAXSystemDialogSubrole as String) &&
            $0.isMinimized != true
        }

        guard hasModalWindow else {
            return .clear
        }

        guard let mainWindow else {
            return .uncertain
        }

        guard let canSetMinimized = mainWindow.canSetMinimized else {
            return .uncertain
        }

        if canSetMinimized || mainWindow.canRaise {
            return .clear
        }

        return .blocked
    }

    private func pickFrontWindow(from windows: [AXWindowInfo]) -> AXWindowInfo? {
        if let focused = windows.first(where: { $0.isFocused == true }) {
            return focused
        }

        if let main = windows.first(where: { $0.isMain == true }) {
            return main
        }

        return windows.first(where: { $0.isVisible == true }) ?? windows.first
    }

    private func standardWindows(for pid: pid_t) -> [AXWindowInfo] {
        let appElement = AXUIElementCreateApplication(pid)
        guard let windowElements = elementArrayAttribute(kAXWindowsAttribute as String, from: appElement) else {
            return []
        }

        let allWindows = windowElements.compactMap { buildWindowInfo(for: $0) }
        let standard = allWindows.filter { $0.isStandardWindow }

        // Some apps (for example Electron variants) expose unusual AX roles.
        // Fall back to all actionable windows to avoid no-op behavior.
        if standard.isEmpty {
            return allWindows
        }

        return standard
    }

    private func buildWindowInfo(for element: AXUIElement) -> AXWindowInfo? {
        let windowID = intAttribute(AXCustomAttribute.windowNumber, from: element) ?? fallbackWindowID(for: element)

        return AXWindowInfo(
            element: element,
            windowID: windowID,
            role: stringAttribute(kAXRoleAttribute as String, from: element),
            subrole: stringAttribute(kAXSubroleAttribute as String, from: element),
            isMinimized: boolAttribute(kAXMinimizedAttribute as String, from: element),
            isVisible: boolAttribute(AXCustomAttribute.visible, from: element),
            isFullScreen: boolAttribute(AXCustomAttribute.fullScreen, from: element),
            isMain: boolAttribute(kAXMainAttribute as String, from: element),
            isFocused: boolAttribute(kAXFocusedAttribute as String, from: element),
            canSetMinimized: isAttributeSettable(kAXMinimizedAttribute as String, on: element),
            canRaise: actionSupported(kAXRaiseAction as String, on: element)
        )
    }

    private func exitFullscreen(window: AXWindowInfo, timeoutSeconds: TimeInterval) async -> Bool {
        var machine = FullscreenTransitionStateMachine()
        machine.apply(.begin)

        let didRequest = setBoolAttribute(AXCustomAttribute.fullScreen, value: false, on: window.element)
        guard didRequest else {
            machine.apply(.exitRequestFailed)
            return machine.state == .exited
        }

        machine.apply(.waiting)

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if boolAttribute(AXCustomAttribute.fullScreen, from: window.element) == false {
                machine.apply(.exited)
                return true
            }

            try? await Task.sleep(for: .milliseconds(50))
        }

        machine.apply(.timeout)
        return false
    }

    private func setBoolAttribute(_ attribute: String, value: Bool, on element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(element, attribute as CFString, value as CFBoolean) == .success
    }

    private func boolAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else {
            return nil
        }
        return value as? Bool
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else {
            return nil
        }
        return value as? String
    }

    private func intAttribute(_ attribute: String, from element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else {
            return nil
        }

        if let number = value as? NSNumber {
            return number.intValue
        }

        return nil
    }

    private func fallbackWindowID(for element: AXUIElement) -> Int {
        Int(bitPattern: Unmanaged.passUnretained(element).toOpaque())
    }

    private func elementArrayAttribute(_ attribute: String, from element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else {
            return nil
        }

        return value as? [AXUIElement]
    }

    private func isAttributeSettable(_ attribute: String, on element: AXUIElement) -> Bool? {
        var settable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        guard result == .success else {
            return nil
        }
        return settable.boolValue
    }

    private func actionSupported(_ action: String, on element: AXUIElement) -> Bool {
        var value: CFArray?
        let result = AXUIElementCopyActionNames(element, &value)
        guard result == .success, let actions = value as? [String] else {
            return false
        }

        return actions.contains(action)
    }

    private func debugLog(_ message: String) {
        guard isDebugLoggingEnabled else {
            return
        }
        NSLog("DockClickMinimize window: \(message)")
    }
}
