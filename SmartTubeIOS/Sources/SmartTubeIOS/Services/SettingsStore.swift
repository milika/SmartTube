#if canImport(SwiftUI)
import Foundation

// MARK: - SettingsStore
//
// Persists `AppSettings` in `UserDefaults` and notifies observers via
// `@Published`.  Used as an `@EnvironmentObject` throughout the app.

@MainActor
public final class SettingsStore: ObservableObject {

    @Published public var settings: AppSettings {
        didSet { save() }
    }

    private static let key = "smarttube_app_settings"

    public init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = AppSettings()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    public func reset() {
        settings = AppSettings()
    }
}
#endif
