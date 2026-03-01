import ApplicationServices
import AppKit
import Foundation

struct DockClickResolution {
    let app: NSRunningApplication
    let confidence: Double
    let clickPoint: CGPoint
    let timestamp: CFAbsoluteTime
}

enum DockClickHandling {
    case passThrough
    case consume
}

final class DockEventResolver {
    typealias Handler = (DockClickResolution) -> DockClickHandling

    private let gate: DockResolutionConfidenceGate
    private let debounceInterval: CFAbsoluteTime

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var handler: Handler?

    private var lastResolvedPID: pid_t = -1
    private var lastResolvedAt: CFAbsoluteTime = 0
    private let isDebugLoggingEnabled = ProcessInfo.processInfo.environment["DOCKCLICK_DEBUG"] == "1"

    init(confidenceThreshold: Double = 0.8, debounceInterval: CFAbsoluteTime = 0.18) {
        self.gate = DockResolutionConfidenceGate(threshold: confidenceThreshold)
        self.debounceInterval = debounceInterval
    }

    var isRunning: Bool {
        eventTap != nil
    }

    func start(handler: @escaping Handler) {
        guard eventTap == nil else {
            return
        }

        self.handler = handler

        let mask = CGEventMask(1) << CGEventType.leftMouseDown.rawValue
        let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: DockEventResolver.tapCallback,
            userInfo: userInfo
        ) else {
            self.handler = nil
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source

        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }

        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        guard let eventTap else {
            return
        }

        CGEvent.tapEnable(tap: eventTap, enable: false)

        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }

        CFMachPortInvalidate(eventTap)

        self.eventTap = nil
        self.runLoopSource = nil
        self.handler = nil
    }

    deinit {
        stop()
    }

    private static let tapCallback: CGEventTapCallBack = { proxy, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }

        let resolver = Unmanaged<DockEventResolver>.fromOpaque(userInfo).takeUnretainedValue()
        return resolver.handle(proxy: proxy, type: type, event: event)
    }

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .leftMouseDown else {
            return Unmanaged.passUnretained(event)
        }

        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return Unmanaged.passUnretained(event)
        }

        let point = event.location

        guard let resolution = resolveDockClick(at: point) else {
            return Unmanaged.passUnretained(event)
        }

        guard !isDebounced(resolution: resolution) else {
            return Unmanaged.passUnretained(event)
        }

        let decision = handler?(resolution) ?? .passThrough

        switch decision {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .consume:
            return nil
        }
    }

    private func isDebounced(resolution: DockClickResolution) -> Bool {
        let isRapidRepeat = resolution.timestamp - lastResolvedAt <= debounceInterval
        let sameApp = resolution.app.processIdentifier == lastResolvedPID
        if isRapidRepeat && sameApp {
            return true
        }

        lastResolvedAt = resolution.timestamp
        lastResolvedPID = resolution.app.processIdentifier
        return false
    }

    private func resolveDockClick(at point: CGPoint) -> DockClickResolution? {
        guard let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier else {
            return nil
        }

        let system = AXUIElementCreateSystemWide()
        var elementRef: AXUIElement?
        let copyResult = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &elementRef)
        guard copyResult == .success, let element = elementRef else {
            return nil
        }

        // Hard safety gate: only treat clicks as Dock clicks when AX hit-testing
        // reports an element owned by the Dock process.
        guard processIdentifier(of: element) == dockPID else {
            return nil
        }

        guard let dockItem = findDockItem(startingAt: element, dockPID: dockPID) else {
            debugLog("No Dock item found at click point (\(Int(point.x)), \(Int(point.y)))")
            return nil
        }

        guard let (app, confidence) = resolveApplicationFromDockItem(dockItem) else {
            debugLog("Could not resolve Dock item to application")
            return nil
        }

        guard gate.shouldHandle(confidence: confidence) else {
            debugLog("Resolution confidence too low: \(confidence)")
            return nil
        }

        debugLog("Resolved Dock click to \(app.bundleIdentifier ?? "?") confidence=\(confidence)")
        return DockClickResolution(
            app: app,
            confidence: confidence,
            clickPoint: point,
            timestamp: CFAbsoluteTimeGetCurrent()
        )
    }

    private func findDockItem(startingAt start: AXUIElement, dockPID: pid_t) -> AXUIElement? {
        var current: AXUIElement? = start

        for _ in 0..<16 {
            guard let candidate = current else {
                return nil
            }

            guard processIdentifier(of: candidate) == dockPID else {
                return nil
            }

            if isLikelyDockItem(candidate) {
                return candidate
            }

            current = elementAttribute(kAXParentAttribute as String, from: candidate)
        }

        return nil
    }

    private func isLikelyDockItem(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(kAXRoleAttribute as String, from: element) ?? ""
        let identifier = stringAttribute(kAXIdentifierAttribute as String, from: element)?.lowercased() ?? ""

        if role == "AXDockItem" {
            return true
        }

        if role == "AXButton" {
            return true
        }

        if identifier.contains("dock") || identifier.contains("tile") {
            return true
        }

        return false
    }

    private func resolveApplicationFromDockItem(_ dockItem: AXUIElement) -> (NSRunningApplication, Double)? {
        let runningApps = NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular && app.bundleIdentifier != nil
        }

        if let identifier = stringAttribute(kAXIdentifierAttribute as String, from: dockItem),
           let bundleID = extractBundleIdentifier(identifier),
           let app = runningApps.first(where: { $0.bundleIdentifier == bundleID }) {
            return (app, 0.99)
        }

        if let url = urlAttribute(kAXURLAttribute as String, from: dockItem) {
            let bundle = Bundle(url: url)
            if let bundleID = bundle?.bundleIdentifier,
               let app = runningApps.first(where: { $0.bundleIdentifier == bundleID }) {
                return (app, 0.95)
            }
        }

        let candidateNames = [
            stringAttribute(kAXTitleAttribute as String, from: dockItem),
            stringAttribute(kAXDescriptionAttribute as String, from: dockItem),
            stringAttribute(kAXHelpAttribute as String, from: dockItem)
        ]
        .compactMap { $0 }
        .map(normalizedAppName(_:))
        .filter { !$0.isEmpty }

        for candidate in candidateNames {
            let matches = runningApps.filter {
                normalizedAppName($0.localizedName ?? "") == candidate
            }

            if matches.count == 1, let app = matches.first {
                return (app, 0.85)
            }
        }

        return nil
    }

    private func extractBundleIdentifier(_ rawIdentifier: String) -> String? {
        if rawIdentifier.contains(".") {
            let parts = rawIdentifier.split(whereSeparator: { $0 == " " || $0 == ":" || $0 == "/" })
            if let bundleLike = parts.first(where: { $0.contains(".") }) {
                let candidate = String(bundleLike)
                if candidate.hasPrefix("com.") || candidate.contains(".") {
                    return candidate
                }
            }
        }
        return nil
    }

    private func normalizedAppName(_ raw: String) -> String {
        let stripped = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let components = stripped.split(separator: " ")
        return components.first.map { String($0).lowercased() } ?? ""
    }

    private func processIdentifier(of element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else {
            return nil
        }
        return value as? String
    }

    private func urlAttribute(_ attribute: String, from element: AXUIElement) -> URL? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else {
            return nil
        }

        return value as? URL
    }

    private func elementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value else {
            return nil
        }

        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeDowncast(value as AnyObject, to: AXUIElement.self)
    }

    private func debugLog(_ message: String) {
        guard isDebugLoggingEnabled else {
            return
        }
        NSLog("DockClickMinimize resolver: \(message)")
    }
}
