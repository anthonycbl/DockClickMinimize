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
    let orderedWindowTitles: [String?]
    let lastActiveWindowID: Int?
    let lastActiveWindowTitle: String?
    let createdAt: Date
}

private struct AXWindowInfo {
    let element: AXUIElement
    let windowID: Int
    // False when the app doesn't expose AXWindowNumber: windowID is then a
    // per-read element pointer that gets reused, so it can't identify a window.
    let hasStableID: Bool
    let title: String?
    let role: String?
    let subrole: String?
    let isMinimized: Bool?
    let isVisible: Bool?
    let isFullScreen: Bool?
    let isMain: Bool?
    let isFocused: Bool?

    var isStandardWindow: Bool {
        let roleLooksWindowLike = role == nil || role == kAXWindowRole as String
        return roleLooksWindowLike && subrole != kAXSystemDialogSubrole as String
    }
}

@MainActor
final class WindowController {
    private var restoreLedgerByPID: [pid_t: RestoreLedger] = [:]
    private let isDebugLoggingEnabled = ProcessInfo.processInfo.environment["DOCKCLICK_DEBUG"] == "1"

    func handleFrontmostClick(app: NSRunningApplication, preferences: AppPreferences) async {
        pruneLedgersForTerminatedApps()
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
            await restoreWindows(pid: pid, windows: windows, behavior: preferences.restoreBehavior)
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
        var minimizedIDs = minimize(windows: targets)
        for id in await retryIgnoredMinimizes(targets) where !minimizedIDs.contains(id) {
            minimizedIDs.append(id)
        }
        debugLog("Minimize targets=\(targets.count), minimized=\(minimizedIDs.count)")

        guard !minimizedIDs.isEmpty else {
            return
        }

        restoreLedgerByPID[pid] = RestoreLedger(
            orderedWindowIDs: minimizedIDs,
            orderedWindowTitles: minimizedIDs.map { id in targets.first(where: { $0.windowID == id })?.title },
            lastActiveWindowID: frontWindow.windowID,
            lastActiveWindowTitle: frontWindow.title,
            createdAt: Date()
        )
    }

    func minimizeImmediately(app: NSRunningApplication) -> Bool {
        let windows = standardWindows(for: app.processIdentifier)
        let minimizableWindows = windows.filter { $0.isMinimized != true }

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

    private func pruneLedgersForTerminatedApps() {
        restoreLedgerByPID = restoreLedgerByPID.filter { pid, _ in
            NSRunningApplication(processIdentifier: pid)?.isTerminated == false
        }
    }

    private func shouldRestore(pid: pid_t, windows: [AXWindowInfo], behavior: RestoreBehavior) -> Bool {
        let currentlyMinimized = windows.filter { $0.isMinimized == true }
        let currentlyUnminimized = windows.filter { $0.isMinimized != true }
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

    private func restoreWindows(pid: pid_t, windows: [AXWindowInfo], behavior: RestoreBehavior) async {
        let ledger = restoreLedgerByPID[pid]
        let minimizedNow = windows.filter { $0.isMinimized == true }
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
            if let ledger {
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

        // Identify the window that was active when we minimized.
        let lastActive = ledger.flatMap { ledger in
            targets.first(where: { matches($0, id: ledger.lastActiveWindowID, title: ledger.lastActiveWindowTitle) })
        }

        restoreLedgerByPID[pid] = nil

        guard let lastActive else {
            for target in targets {
                _ = setBoolAttribute(kAXMinimizedAttribute as String, value: false, on: target.element)
            }
            debugLog("Restore targets=\(targets.count), no last-active match")
            // Raising immediately gets ignored while the un-minimize animation
            // is still running; wait for it to settle, then select the window.
            if let raiseTarget = targets.last {
                try? await Task.sleep(for: .milliseconds(250))
                raise(raiseTarget)
            }
            return
        }

        guard behavior == .restoreAllMinimizedWindows else {
            _ = setBoolAttribute(kAXMinimizedAttribute as String, value: false, on: lastActive.element)
            debugLog("Restored last-active window only")
            return
        }

        // Restore the other windows we minimized first and the last-active one
        // last, so it ends up on top. Only windows in the ledger are touched: a
        // minimized Finder window lists each of its tabs as a separate minimized
        // AX window, and un-minimizing a background tab switches the selected
        // tab. Background tabs never enter the ledger because an open Finder
        // window only lists its selected tab.
        var others: [AXWindowInfo] = []
        if let ledger {
            var pool = minimizedNow.filter { $0.element !== lastActive.element }
            for (id, title) in zip(ledger.orderedWindowIDs, ledger.orderedWindowTitles) {
                if let index = pool.firstIndex(where: { matches($0, id: id, title: title) }) {
                    others.append(pool.remove(at: index))
                }
            }
        }

        for window in others {
            _ = setBoolAttribute(kAXMinimizedAttribute as String, value: false, on: window.element)
        }
        // Apps like Word and Excel drop requests that arrive back-to-back, so
        // give the others a moment before restoring the last-active window.
        if !others.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
        }
        _ = setBoolAttribute(kAXMinimizedAttribute as String, value: false, on: lastActive.element)

        // Anything still minimized was minimized by the user rather than by us;
        // restore-all brings it back too. Wait until background Finder tabs are
        // no longer listed (they disappear once their window is open). Nothing
        // visible happens during this wait.
        try? await Task.sleep(for: .milliseconds(250))
        let stragglers = standardWindows(for: pid).filter { $0.isMinimized == true }
        debugLog("Restored \(others.count) other windows, then last-active, then \(stragglers.count) stragglers")
        guard !stragglers.isEmpty else {
            return
        }

        for window in stragglers {
            _ = setBoolAttribute(kAXMinimizedAttribute as String, value: false, on: window.element)
        }
        // Stragglers landed on top; put the last-active window back in front.
        // Raising immediately gets ignored while the un-minimize animation is
        // still running.
        try? await Task.sleep(for: .milliseconds(250))
        raise(lastActive)
    }

    private func matches(_ window: AXWindowInfo, id: Int?, title: String?) -> Bool {
        if window.hasStableID {
            return window.windowID == id
        }
        return title != nil && window.title == title
    }

    private func raise(_ window: AXWindowInfo) {
        _ = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        _ = setBoolAttribute(kAXMainAttribute as String, value: true, on: window.element)
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
        let minimizable = windows.filter { $0.isMinimized != true }

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

        // Attempting the set and checking the result replaces a separate
        // "is this settable?" AX round-trip per window.
        for window in windows {
            let didSet = setBoolAttribute(kAXMinimizedAttribute as String, value: true, on: window.element)
            if didSet {
                minimized.append(window.windowID)
            }
        }

        return minimized
    }

    // Some apps (e.g. Microsoft Excel and Word) accept every minimize request
    // but act only on the first while its animation runs, silently dropping
    // the rest. Re-check the real state and retry the stragglers.
    private func retryIgnoredMinimizes(_ windows: [AXWindowInfo]) async -> [Int] {
        var pending = windows
        for _ in 0..<6 {
            pending = pending.filter { boolAttribute(kAXMinimizedAttribute as String, from: $0.element) == false }
            guard !pending.isEmpty else {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
            let retried = minimize(windows: pending)
            debugLog("Retried minimize for \(pending.count) ignored windows, accepted=\(retried.count)")
        }
        return windows.filter { boolAttribute(kAXMinimizedAttribute as String, from: $0.element) == true }.map(\.windowID)
    }

    private func handleBlockedModal(windows: [AXWindowInfo], mainWindow: AXWindowInfo?, behavior: ModalBlockingBehavior) {
        switch behavior {
        case .doNothing:
            return
        case .minimizeMainWindowBehindModal:
            guard let mainWindow else {
                return
            }
            _ = setBoolAttribute(kAXMinimizedAttribute as String, value: true, on: mainWindow.element)
        case .minimizeModalIfPossible:
            guard let modal = windows.first(where: {
                $0.subrole == kAXDialogSubrole as String || $0.subrole == kAXSystemDialogSubrole as String
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

        // Capability probes run only on this modal path, never on the common
        // minimize/restore paths.
        guard let canSetMinimized = isAttributeSettable(kAXMinimizedAttribute as String, on: mainWindow.element) else {
            return .uncertain
        }

        if canSetMinimized || actionSupported(kAXRaiseAction as String, on: mainWindow.element) {
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

    // Fetches all window attributes in a single AX round-trip instead of one
    // IPC call per attribute. Unsupported attributes come back as non-matching
    // placeholder values and read as nil.
    private static let windowAttributeNames: [String] = [
        AXCustomAttribute.windowNumber,
        kAXTitleAttribute as String,
        kAXRoleAttribute as String,
        kAXSubroleAttribute as String,
        kAXMinimizedAttribute as String,
        AXCustomAttribute.visible,
        AXCustomAttribute.fullScreen,
        kAXMainAttribute as String,
        kAXFocusedAttribute as String
    ]

    private func buildWindowInfo(for element: AXUIElement) -> AXWindowInfo? {
        var valuesRef: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(
            element,
            Self.windowAttributeNames as CFArray,
            AXCopyMultipleAttributeOptions(),
            &valuesRef
        )

        guard result == .success,
              let values = valuesRef as? [AnyObject],
              values.count == Self.windowAttributeNames.count else {
            return nil
        }

        return AXWindowInfo(
            element: element,
            windowID: (values[0] as? NSNumber)?.intValue ?? fallbackWindowID(for: element),
            hasStableID: values[0] is NSNumber,
            title: values[1] as? String,
            role: values[2] as? String,
            subrole: values[3] as? String,
            isMinimized: values[4] as? Bool,
            isVisible: values[5] as? Bool,
            isFullScreen: values[6] as? Bool,
            isMain: values[7] as? Bool,
            isFocused: values[8] as? Bool
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
