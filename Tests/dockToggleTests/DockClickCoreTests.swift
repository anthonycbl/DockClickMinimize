import Foundation

#if canImport(XCTest)
import XCTest
@testable import dockToggle

final class DockClickCoreTests: XCTestCase {
    func testRestorePlannerReturnsAllWindowsForRestoreAll() {
        let selected = RestorePlanner.windowsToRestore(
            orderedWindowIDs: [101, 102, 103],
            lastActiveWindowID: 102,
            behavior: .restoreAllMinimizedWindows
        )

        XCTAssertEqual(selected, [101, 102, 103])
    }

    func testRestorePlannerPrefersLastActiveForRestoreLast() {
        let selected = RestorePlanner.windowsToRestore(
            orderedWindowIDs: [201, 202],
            lastActiveWindowID: 202,
            behavior: .restoreLastActiveWindow
        )

        XCTAssertEqual(selected, [202])
    }

    func testFullscreenStateMachineTimeoutPath() {
        var machine = FullscreenTransitionStateMachine()
        machine.apply(.begin)
        machine.apply(.waiting)
        machine.apply(.timeout)

        XCTAssertEqual(machine.state, .failedTimeout)
    }

    func testSafetyNoOpWhenModalStateIsUncertain() {
        let shouldNoOp = SafetyDecisions.shouldNoOpForModal(.uncertain, behavior: .minimizeModalIfPossible)
        XCTAssertTrue(shouldNoOp)
    }

    func testSafetyNoOpBehaviorForBlockedModalByPreference() {
        XCTAssertTrue(SafetyDecisions.shouldNoOpForModal(.blocked, behavior: .doNothing))
        XCTAssertFalse(SafetyDecisions.shouldNoOpForModal(.blocked, behavior: .minimizeMainWindowBehindModal))
        XCTAssertFalse(SafetyDecisions.shouldNoOpForModal(.blocked, behavior: .minimizeModalIfPossible))
    }

    func testConfidenceGateRejectsLowConfidenceResolution() {
        let gate = DockResolutionConfidenceGate(threshold: 0.8)
        XCTAssertFalse(gate.shouldHandle(confidence: 0.79))
        XCTAssertTrue(gate.shouldHandle(confidence: 0.8))
    }

    @MainActor
    func testPreferencesStoreDefaultsWhenPersistedPayloadIsInvalid() {
        let suiteName = "DockClickMinimizeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }

        defaults.set("not-json".data(using: .utf8), forKey: "DockClickMinimize.Preferences.v1")

        let store = PreferencesStore(defaults: defaults)

        XCTAssertEqual(store.preferences, .default)

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDefaultPreferencesMatchProductSpecDefaults() {
        let defaults = AppPreferences.default

        XCTAssertTrue(defaults.enabled)
        XCTAssertFalse(defaults.launchAtLogin)
        XCTAssertEqual(defaults.frontmostMinimizeBehavior, .minimizeAllWindows)
        XCTAssertEqual(defaults.restoreBehavior, .restoreAllMinimizedWindows)
        XCTAssertEqual(defaults.modalBlockingBehavior, .doNothing)
        XCTAssertEqual(defaults.fullscreenBehavior, .exitFullscreenThenMinimize)
        XCTAssertEqual(defaults.nonFrontmostClickBehavior, .bringToFront)
        XCTAssertEqual(defaults.excludedBundleIdentifiers, [])
    }

    func testOptionEnumsExposeExpectedCases() {
        XCTAssertEqual(FrontmostMinimizeBehavior.allCases.count, 2)
        XCTAssertEqual(RestoreBehavior.allCases.count, 2)
        XCTAssertEqual(ModalBlockingBehavior.allCases.count, 3)
        XCTAssertEqual(FullscreenBehavior.allCases.count, 2)
        XCTAssertEqual(NonFrontmostClickBehavior.allCases.count, 2)
    }

    func testRestoreDecisionRestoreAllRequiresAllRelevantWindowsMinimized() {
        XCTAssertFalse(
            RestoreDecision.shouldRestore(
                behavior: .restoreAllMinimizedWindows,
                minimizedCount: 1,
                unminimizedCount: 1,
                ledgerMinimizationStates: [true]
            )
        )

        XCTAssertTrue(
            RestoreDecision.shouldRestore(
                behavior: .restoreAllMinimizedWindows,
                minimizedCount: 2,
                unminimizedCount: 0,
                ledgerMinimizationStates: [true]
            )
        )
    }

    func testRestoreDecisionRestoreLastUsesLedgerFallback() {
        XCTAssertTrue(
            RestoreDecision.shouldRestore(
                behavior: .restoreLastActiveWindow,
                minimizedCount: 1,
                unminimizedCount: 0,
                ledgerMinimizationStates: []
            )
        )

        XCTAssertTrue(
            RestoreDecision.shouldRestore(
                behavior: .restoreLastActiveWindow,
                minimizedCount: 0,
                unminimizedCount: 2,
                ledgerMinimizationStates: [true, true]
            )
        )

        XCTAssertFalse(
            RestoreDecision.shouldRestore(
                behavior: .restoreLastActiveWindow,
                minimizedCount: 0,
                unminimizedCount: 2,
                ledgerMinimizationStates: [true, false]
            )
        )
    }
}
#endif
