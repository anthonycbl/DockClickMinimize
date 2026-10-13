import SwiftUI

struct OnboardingView: View {
    @ObservedObject var appState: AppState
    let onContinue: () -> Void

    private let permissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("DockClick Minimize")
                .font(.title2.weight(.semibold))

            Text("Clicking the Dock icon of the frontmost app toggles minimize/restore based on your settings.")
                .fixedSize(horizontal: false, vertical: true)

            Text("Accessibility and Input Monitoring are required. If either permission is missing, override behavior stays disabled.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Accessibility:")
                Spacer()
                Text(appState.permissionStatus.accessibilityGranted ? "Granted" : "Not granted")
            }

            HStack {
                Text("Input Monitoring:")
                Spacer()
                Text(appState.permissionStatus.inputMonitoringGranted ? "Granted" : "Not granted")
            }

            HStack {
                Button("Grant Accessibility") {
                    appState.requestAccessibilityPermission()
                    appState.openAccessibilitySettings()
                }

                Button("Grant Input Monitoring") {
                    appState.requestInputMonitoringPermission()
                    appState.openInputMonitoringSettings()
                }

                Button("Refresh") {
                    appState.refreshPermissionStatus()
                }
            }

            Divider()

            HStack {
                Spacer()

                Button("Continue") {
                    appState.markOnboardingSeen()
                    onContinue()
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .onReceive(permissionTimer) { _ in
            appState.refreshPermissionStatus()
        }
    }
}
