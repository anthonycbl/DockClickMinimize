import AppKit
import Combine
import SwiftUI

@main
struct DockClickMinimizeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let appState = AppState()
    private var cancellables: Set<AnyCancellable> = []

    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?

    private let enabledMenuItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
    private let launchAtLoginMenuItem = NSMenuItem(title: "Launch at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var suppressionWindows: Set<ObjectIdentifier> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        bindState()
        appState.refreshPermissionStatus()

        if appState.shouldShowOnboarding {
            showOnboarding()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenuStates()
    }

    @objc private func toggleEnabled() {
        appState.setEnabled(!appState.preferences.enabled)
    }

    @objc private func toggleLaunchAtLogin() {
        appState.setLaunchAtLogin(!appState.preferences.launchAtLogin)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let root = SettingsView(appState: appState)
            let hosting = NSHostingController(rootView: root)

            let window = NSWindow(contentViewController: hosting)
            window.title = "DockClick Minimize Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 760, height: 700))
            window.center()
            window.delegate = self
            settingsWindow = window
        }

        guard let settingsWindow else {
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindow.makeKeyAndOrderFront(nil)
    }

    @objc private func refreshPermissions() {
        appState.refreshPermissionStatus()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = item.button {
            button.title = "DockClick"
            button.imagePosition = .imageLeading
            button.image = NSImage(systemSymbolName: "rectangle.stack.badge.minus", accessibilityDescription: "DockClick")
        }

        let menu = NSMenu()
        menu.delegate = self

        enabledMenuItem.target = self
        launchAtLoginMenuItem.target = self

        menu.addItem(enabledMenuItem)
        menu.addItem(launchAtLoginMenuItem)
        menu.addItem(.separator())

        let permissionsItem = NSMenuItem(title: "Refresh permissions", action: #selector(refreshPermissions), keyEquivalent: "")
        permissionsItem.target = self
        menu.addItem(permissionsItem)

        let settingsItem = NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit DockClick Minimize", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu

        statusItem = item
        statusMenu = menu

        refreshMenuStates()
    }

    private func bindState() {
        appState.preferencesStore.$preferences
            .sink { [weak self] _ in
                self?.refreshMenuStates()
            }
            .store(in: &cancellables)

        appState.$permissionStatus
            .sink { [weak self] _ in
                self?.refreshMenuStates()
            }
            .store(in: &cancellables)
    }

    private func refreshMenuStates() {
        enabledMenuItem.state = appState.preferences.enabled ? .on : .off
        launchAtLoginMenuItem.state = appState.preferences.launchAtLogin ? .on : .off

        enabledMenuItem.isEnabled = appState.permissionStatus.isOperational || !appState.preferences.enabled
    }

    private func showOnboarding() {
        if onboardingWindow == nil {
            let root = OnboardingView(appState: appState) { [weak self] in
                self?.onboardingWindow?.close()
            }
            let hosting = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Welcome to DockClick Minimize"
            window.styleMask = [.titled, .closable]
            window.center()
            window.delegate = self
            onboardingWindow = window
        }

        guard let onboardingWindow else {
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, isManagedWindow(window) else {
            return
        }

        setSuppression(for: window, enabled: true)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, isManagedWindow(window) else {
            return
        }

        setSuppression(for: window, enabled: false)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            return
        }

        setSuppression(for: window, enabled: false)

        if window === settingsWindow {
            settingsWindow = nil
        }

        if window === onboardingWindow {
            onboardingWindow = nil
        }
    }

    private func isManagedWindow(_ window: NSWindow) -> Bool {
        window === settingsWindow || window === onboardingWindow
    }

    private func setSuppression(for window: NSWindow, enabled: Bool) {
        let identifier = ObjectIdentifier(window)

        if enabled {
            guard suppressionWindows.insert(identifier).inserted else {
                return
            }
            appState.beginInteractionSuppression()
            return
        }

        guard suppressionWindows.remove(identifier) != nil else {
            return
        }

        appState.endInteractionSuppression()
    }
}
