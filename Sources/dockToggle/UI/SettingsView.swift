import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var selectedBundleIDToExclude: String = ""

    // Keep permission status live while the window is open, so grants made in
    // System Settings show up without pressing Refresh.
    private let permissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var excludedBundleIDs: [String] {
        appState.preferences.excludedBundleIdentifiers.sorted()
    }

    private var includableApps: [NSRunningApplication] {
        appState.runningRegularApps().filter { app in
            guard let bundleID = app.bundleIdentifier else { return false }
            return !appState.preferences.excludedBundleIdentifiers.contains(bundleID)
        }
    }

    private var appVersionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        guard let short else {
            return "dev (running unbundled)"
        }

        if let build {
            return "\(short) (build \(build))"
        }
        return short
    }

    var body: some View {
        Form {
            Section("About") {
                LabeledContent("Version") {
                    Text(appVersionString)
                }
            }

            Section("Permissions") {
                LabeledContent("Accessibility") {
                    Text(appState.permissionStatus.accessibilityGranted ? "Granted" : "Missing")
                }
                LabeledContent("Input Monitoring") {
                    Text(appState.permissionStatus.inputMonitoringGranted ? "Granted" : "Missing")
                }

                HStack {
                    Button("Open Accessibility Settings") {
                        appState.openAccessibilitySettings()
                    }

                    Button("Open Input Monitoring Settings") {
                        appState.openInputMonitoringSettings()
                    }

                    Button("Refresh") {
                        appState.refreshPermissionStatus()
                    }
                }

                if !appState.isFeatureOperational {
                    Text("Feature is disabled until both permissions are granted.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("General") {
                Toggle("Enabled", isOn: Binding(
                    get: { appState.preferences.enabled },
                    set: { appState.setEnabled($0) }
                ))

                Toggle("Launch at login", isOn: Binding(
                    get: { appState.preferences.launchAtLogin },
                    set: { appState.setLaunchAtLogin($0) }
                ))
            }

            Section("Frontmost app Dock click") {
                Picker("Minimize behavior", selection: Binding(
                    get: { appState.preferences.frontmostMinimizeBehavior },
                    set: { appState.setFrontmostMinimizeBehavior($0) }
                )) {
                    ForEach(FrontmostMinimizeBehavior.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.menu)

                Picker("Restore behavior", selection: Binding(
                    get: { appState.preferences.restoreBehavior },
                    set: { appState.setRestoreBehavior($0) }
                )) {
                    ForEach(RestoreBehavior.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.menu)

                Picker("Modal blocking behavior", selection: Binding(
                    get: { appState.preferences.modalBlockingBehavior },
                    set: { appState.setModalBlockingBehavior($0) }
                )) {
                    ForEach(ModalBlockingBehavior.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.menu)

                Picker("Fullscreen behavior", selection: Binding(
                    get: { appState.preferences.fullscreenBehavior },
                    set: { appState.setFullscreenBehavior($0) }
                )) {
                    ForEach(FullscreenBehavior.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Non-frontmost app Dock click") {
                Picker("Behavior", selection: Binding(
                    get: { appState.preferences.nonFrontmostClickBehavior },
                    set: { appState.setNonFrontmostBehavior($0) }
                )) {
                    ForEach(NonFrontmostClickBehavior.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Exclusions") {
                if excludedBundleIDs.isEmpty {
                    Text("No excluded apps")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(excludedBundleIDs, id: \.self) { bundleID in
                        HStack {
                            Image(nsImage: iconForBundleID(bundleID))
                                .resizable()
                                .frame(width: 16, height: 16)

                            Text(nameForBundleID(bundleID))
                            Spacer()
                            Text(bundleID)
                                .foregroundStyle(.secondary)
                            Button("Remove") {
                                appState.removeExclusion(bundleIdentifier: bundleID)
                            }
                        }
                    }
                }

                HStack {
                    Picker("Add running app", selection: $selectedBundleIDToExclude) {
                        Text("Select app").tag("")
                        ForEach(includableApps, id: \.processIdentifier) { app in
                            if let bundleID = app.bundleIdentifier {
                                Text(app.localizedName ?? bundleID).tag(bundleID)
                            }
                        }
                    }
                    .pickerStyle(.menu)

                    Button("Add") {
                        appState.exclude(bundleIdentifier: selectedBundleIDToExclude)
                        selectedBundleIDToExclude = ""
                    }
                    .disabled(selectedBundleIDToExclude.isEmpty)

                    Button("Exclude current frontmost app") {
                        appState.excludeFrontmostApp()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .frame(width: 760, height: 680)
        .onReceive(permissionTimer) { _ in
            appState.refreshPermissionStatus()
        }
    }

    private func nameForBundleID(_ bundleID: String) -> String {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let bundle = Bundle(url: appURL),
           let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String {
            return name
        }

        return bundleID
    }

    private func iconForBundleID(_ bundleID: String) -> NSImage {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: appURL.path)
        }

        return NSImage(named: NSImage.applicationIconName) ?? NSImage()
    }
}
