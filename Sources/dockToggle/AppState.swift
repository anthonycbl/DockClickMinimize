import AppKit
import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var permissionStatus: PermissionStatus
    @Published private(set) var preferences: AppPreferences

    let preferencesStore: PreferencesStore

    private let permissionManager: PermissionManager
    private let launchAtLoginManager: LaunchAtLoginManager
    private let windowController: WindowController
    private let coordinator: DockClickCoordinator
    private let dockResolver: DockEventResolver

    private let defaults: UserDefaults
    private let onboardingSeenKey = "DockClickMinimize.OnboardingSeen"
    private var interactionSuppressionCount = 0

    private var cancellables: Set<AnyCancellable> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.permissionManager = PermissionManager()
        self.launchAtLoginManager = LaunchAtLoginManager()
        self.preferencesStore = PreferencesStore()
        self.windowController = WindowController()
        self.dockResolver = DockEventResolver()

        let initialPermissions = self.permissionManager.status()
        let initialPreferences = self.preferencesStore.preferences
        permissionStatus = initialPermissions
        preferences = initialPreferences

        coordinator = DockClickCoordinator(
            windowController: self.windowController,
            initialSnapshot: RuntimeSnapshot(
                enabled: initialPreferences.enabled,
                permissions: initialPermissions,
                preferences: initialPreferences
            )
        )

        bindPreferences()
        refreshRuntime()
    }

    var shouldShowOnboarding: Bool {
        !defaults.bool(forKey: onboardingSeenKey)
    }

    var isFeatureOperational: Bool {
        permissionStatus.isOperational
    }

    func markOnboardingSeen() {
        defaults.set(true, forKey: onboardingSeenKey)
    }

    func refreshPermissionStatus() {
        permissionStatus = permissionManager.status()
        updateRuntimeSnapshot()
        refreshRuntime()
    }

    func requestAccessibilityPermission() {
        permissionManager.requestAccessibilityPrompt()
    }

    func openAccessibilitySettings() {
        permissionManager.openAccessibilitySettings()
    }

    func openInputMonitoringSettings() {
        permissionManager.openInputMonitoringSettings()
    }

    func setEnabled(_ enabled: Bool) {
        preferencesStore.update { $0.enabled = enabled }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        preferencesStore.update { $0.launchAtLogin = enabled }
    }

    func setFrontmostMinimizeBehavior(_ value: FrontmostMinimizeBehavior) {
        preferencesStore.update { $0.frontmostMinimizeBehavior = value }
    }

    func setRestoreBehavior(_ value: RestoreBehavior) {
        preferencesStore.update { $0.restoreBehavior = value }
    }

    func setModalBlockingBehavior(_ value: ModalBlockingBehavior) {
        preferencesStore.update { $0.modalBlockingBehavior = value }
    }

    func setFullscreenBehavior(_ value: FullscreenBehavior) {
        preferencesStore.update { $0.fullscreenBehavior = value }
    }

    func setNonFrontmostBehavior(_ value: NonFrontmostClickBehavior) {
        preferencesStore.update { $0.nonFrontmostClickBehavior = value }
    }

    func exclude(bundleIdentifier: String) {
        preferencesStore.update { prefs in
            prefs.excludedBundleIdentifiers.insert(bundleIdentifier)
        }
    }

    func removeExclusion(bundleIdentifier: String) {
        preferencesStore.update { prefs in
            prefs.excludedBundleIdentifiers.remove(bundleIdentifier)
        }
    }

    func excludeFrontmostApp() {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return
        }
        exclude(bundleIdentifier: bundleID)
    }

    func runningRegularApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    func beginInteractionSuppression() {
        interactionSuppressionCount += 1
        refreshRuntime()
    }

    func endInteractionSuppression() {
        interactionSuppressionCount = max(0, interactionSuppressionCount - 1)
        refreshRuntime()
    }

    private func bindPreferences() {
        preferencesStore.$preferences
            .sink { [weak self] updated in
                guard let self else { return }
                self.preferences = updated
                self.launchAtLoginManager.apply(enabled: updated.launchAtLogin)
                self.updateRuntimeSnapshot()
                self.refreshRuntime()
            }
            .store(in: &cancellables)
    }

    private func updateRuntimeSnapshot() {
        coordinator.update(
            snapshot: RuntimeSnapshot(
                enabled: preferences.enabled,
                permissions: permissionStatus,
                preferences: preferences
            )
        )
    }

    private func refreshRuntime() {
        let shouldRun = preferences.enabled &&
            permissionStatus.isOperational &&
            interactionSuppressionCount == 0

        if shouldRun {
            if !dockResolver.isRunning {
                let coordinator = self.coordinator
                dockResolver.start { resolution in
                    coordinator.handle(resolution)
                }
            }
        } else {
            dockResolver.stop()
        }
    }
}
