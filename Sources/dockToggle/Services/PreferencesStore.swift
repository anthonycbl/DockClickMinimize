import Combine
import Foundation

@MainActor
final class PreferencesStore: ObservableObject {
    @Published private(set) var preferences: AppPreferences

    private let defaults: UserDefaults
    private let key = "DockClickMinimize.Preferences.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(AppPreferences.self, from: data) {
            preferences = decoded
        } else {
            preferences = .default
            persist()
        }
    }

    func update(_ mutate: (inout AppPreferences) -> Void) {
        var copy = preferences
        mutate(&copy)
        preferences = copy
        persist()
    }

    func replace(_ newPreferences: AppPreferences) {
        preferences = newPreferences
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(preferences) else {
            return
        }
        defaults.set(data, forKey: key)
    }
}
