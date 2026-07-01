import Foundation

/// Durable user preferences for the app. Keep this as the single top-level configuration value
/// so future preferences can be added without inventing new persistence paths.
public struct AppConfiguration: Codable, Equatable, Sendable {
    public static let `default` = AppConfiguration()

    /// Point size of the code viewer's font.
    public var fontSize: CGFloat

    public init(fontSize: CGFloat = FontSizes.default) {
        self.fontSize = FontSizes.clamp(fontSize)
    }

    private enum CodingKeys: String, CodingKey {
        case fontSize
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fontSize = try container.decodeIfPresent(CGFloat.self, forKey: .fontSize) ?? FontSizes.default
        self.init(fontSize: fontSize)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fontSize, forKey: .fontSize)
    }
}

/// Small Codable-backed store for app configuration state.
public final class UserDefaultsConfigurationStore<Value: Codable> {
    private let defaults: UserDefaults
    private let key: String
    private let defaultValue: Value
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: UserDefaults = .standard, key: String, defaultValue: Value) {
        self.defaults = defaults
        self.key = key
        self.defaultValue = defaultValue
    }

    public func load() -> Value {
        guard let data = defaults.data(forKey: key),
              let configuration = try? decoder.decode(Value.self, from: data) else {
            return defaultValue
        }
        return configuration
    }

    public func save(_ configuration: Value) {
        guard let data = try? encoder.encode(configuration) else { return }
        defaults.set(data, forKey: key)
    }
}

public typealias AppConfigurationStore = UserDefaultsConfigurationStore<AppConfiguration>

public extension UserDefaultsConfigurationStore where Value == AppConfiguration {
    static func standard(defaults: UserDefaults = .standard) -> AppConfigurationStore {
        AppConfigurationStore(
            defaults: defaults,
            key: "com.judegao.myide.appConfiguration.v1",
            defaultValue: .default
        )
    }
}
