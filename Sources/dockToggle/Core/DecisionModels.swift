import Foundation

enum ModalBlockAssessment: Equatable {
    case clear
    case blocked
    case uncertain
}

struct DockResolutionConfidenceGate {
    let threshold: Double

    func shouldHandle(confidence: Double) -> Bool {
        confidence >= threshold
    }
}

struct SafetyDecisions {
    static func shouldNoOpForModal(_ assessment: ModalBlockAssessment, behavior: ModalBlockingBehavior) -> Bool {
        switch assessment {
        case .clear:
            return false
        case .blocked:
            return behavior == .doNothing
        case .uncertain:
            return true
        }
    }
}

struct RestorePlanner {
    static func windowsToRestore(orderedWindowIDs: [Int], lastActiveWindowID: Int?, behavior: RestoreBehavior) -> [Int] {
        switch behavior {
        case .restoreAllMinimizedWindows:
            return orderedWindowIDs
        case .restoreLastActiveWindow:
            if let lastActiveWindowID {
                return [lastActiveWindowID]
            }
            return orderedWindowIDs.first.map { [$0] } ?? []
        }
    }
}

struct RestoreDecision {
    static func shouldRestore(
        behavior: RestoreBehavior,
        minimizedCount: Int,
        unminimizedCount: Int,
        ledgerMinimizationStates: [Bool]
    ) -> Bool {
        switch behavior {
        case .restoreAllMinimizedWindows:
            return minimizedCount > 0 && unminimizedCount == 0
        case .restoreLastActiveWindow:
            if minimizedCount > 0 && unminimizedCount == 0 {
                return true
            }

            guard !ledgerMinimizationStates.isEmpty else {
                return false
            }

            return ledgerMinimizationStates.allSatisfy { $0 }
        }
    }
}

enum FullscreenTransitionState: Equatable {
    case idle
    case requestExit
    case waitingForExit
    case exited
    case failedAction
    case failedTimeout
}

struct FullscreenTransitionStateMachine {
    private(set) var state: FullscreenTransitionState = .idle

    enum Event {
        case begin
        case exitRequestFailed
        case waiting
        case exited
        case timeout
    }

    mutating func apply(_ event: Event) {
        switch (state, event) {
        case (.idle, .begin):
            state = .requestExit
        case (.requestExit, .exitRequestFailed):
            state = .failedAction
        case (.requestExit, .waiting), (.waitingForExit, .waiting):
            state = .waitingForExit
        case (.requestExit, .exited), (.waitingForExit, .exited):
            state = .exited
        case (.requestExit, .timeout), (.waitingForExit, .timeout):
            state = .failedTimeout
        default:
            break
        }
    }
}
