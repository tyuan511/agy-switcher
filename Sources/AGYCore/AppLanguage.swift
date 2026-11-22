import Foundation

enum AppLanguage: String, CaseIterable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var locale: Locale { Locale(identifier: rawValue) }

    var name: String {
        switch self {
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }

    func text(_ key: String.LocalizationValue) -> String {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        return String(localized: LocalizedStringResource(key, locale: locale, bundle: bundle))
    }

    func errorDescription(_ error: any Error) -> String {
        (error as? AGYError)?.description(in: self) ?? error.localizedDescription
    }
}
