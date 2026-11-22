import SwiftUI

extension EnvironmentValues {
    @Entry var appLanguage: AppLanguage = .simplifiedChinese
}

@MainActor
@Observable
final class AppPreferences {
    enum Appearance: String, CaseIterable {
        case system, light, dark

        var title: String.LocalizationValue {
            switch self {
            case .system: "跟随系统"
            case .light: "浅色"
            case .dark: "深色"
            }
        }

        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    enum WindowCloseBehavior: String, CaseIterable {
        case keepMenuBar, quit

        var title: String.LocalizationValue {
            switch self {
            case .keepMenuBar: "保留菜单栏"
            case .quit: "退出应用"
            }
        }
    }

    private enum Key {
        static let language = "appLanguage"
        static let appearance = "appAppearance"
        static let hideDockIcon = "hideDockIcon"
        static let windowCloseBehavior = "windowCloseBehavior"
        static let automaticallyRefreshQuota = "automaticallyRefreshQuota"
        static let quotaRefreshInterval = "quotaRefreshIntervalMinutes"
    }

    private let defaults: UserDefaults

    var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: Key.language) }
    }

    var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }

    var hideDockIcon: Bool {
        didSet { defaults.set(hideDockIcon, forKey: Key.hideDockIcon) }
    }

    var windowCloseBehavior: WindowCloseBehavior {
        didSet { defaults.set(windowCloseBehavior.rawValue, forKey: Key.windowCloseBehavior) }
    }

    var automaticallyRefreshQuota: Bool {
        didSet { defaults.set(automaticallyRefreshQuota, forKey: Key.automaticallyRefreshQuota) }
    }

    var quotaRefreshInterval: QuotaRefreshInterval {
        didSet { defaults.set(quotaRefreshInterval.rawValue, forKey: Key.quotaRefreshInterval) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = defaults.string(forKey: Key.language).flatMap(AppLanguage.init(rawValue:)) ?? .simplifiedChinese
        appearance = defaults.string(forKey: Key.appearance).flatMap(Appearance.init(rawValue:)) ?? .system
        hideDockIcon = Self.storedHideDockIcon(in: defaults)
        windowCloseBehavior = Self.storedWindowCloseBehavior(in: defaults)
        automaticallyRefreshQuota = defaults.object(forKey: Key.automaticallyRefreshQuota) as? Bool ?? true
        quotaRefreshInterval = QuotaRefreshInterval(rawValue: defaults.integer(forKey: Key.quotaRefreshInterval)) ?? .fiveMinutes
    }

    static func storedHideDockIcon(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: Key.hideDockIcon)
    }

    static func storedWindowCloseBehavior(in defaults: UserDefaults = .standard) -> WindowCloseBehavior {
        defaults.string(forKey: Key.windowCloseBehavior).flatMap(WindowCloseBehavior.init(rawValue:)) ?? .keepMenuBar
    }
}
