import ServiceManagement
import SwiftUI

struct SettingsPage: View {
    @Bindable var preferences: AppPreferences
    let updater: AppUpdater
    @Environment(\.appLanguage) private var language
    @Environment(\.appearsActive) private var appearsActive
    @State private var loginItemStatus = SMAppService.mainApp.status
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section {
                Picker(language.text("语言"), selection: $preferences.language) {
                    ForEach(AppLanguage.allCases, id: \.self) { option in
                        Text(verbatim: option.name).tag(option)
                    }
                }
                Picker(language.text("外观"), selection: $preferences.appearance) {
                    ForEach(AppPreferences.Appearance.allCases, id: \.self) { option in
                        Text(language.text(option.title)).tag(option)
                    }
                }
                Toggle(language.text("隐藏 Dock 图标"), isOn: $preferences.hideDockIcon)
                Picker(language.text("关闭窗口时"), selection: $preferences.windowCloseBehavior) {
                    ForEach(AppPreferences.WindowCloseBehavior.allCases, id: \.self) { option in
                        Text(language.text(option.title)).tag(option)
                    }
                }
                Toggle(isOn: Binding(get: {
                    loginItemStatus == .enabled || loginItemStatus == .requiresApproval
                }, set: setLaunchAtLogin)) {
                    Text(language.text("登录时启动"))
                    Text(language.text("登录 macOS 后驻留菜单栏，账号管理窗口按需打开。"))
                }
                if loginItemStatus == .requiresApproval {
                    Button(language.text("在系统设置中允许登录启动")) {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                }
                if let loginItemError {
                    Text(language.text("无法更新登录项。\(loginItemError)"))
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle(isOn: $preferences.automaticallyRefreshQuota) {
                    Text(language.text("自动刷新配额"))
                    Text(language.text("打开账号管理或菜单栏弹窗时，按设定间隔检查并刷新配额。"))
                }
                Picker(language.text("刷新间隔"), selection: $preferences.quotaRefreshInterval) {
                    ForEach(QuotaRefreshInterval.allCases, id: \.self) { interval in
                        let duration = Duration.seconds(interval.seconds)
                        Text(duration.formatted(.units(allowed: [.minutes], width: .wide).locale(language.locale)))
                            .tag(interval)
                    }
                }
                .disabled(!preferences.automaticallyRefreshQuota)
            }
            if updater.enabled {
                UpdateSettings(updater: updater)
            }
        }
        .formStyle(.grouped)
        .onChange(of: appearsActive, initial: true) { _, active in
            if active { loginItemStatus = SMAppService.mainApp.status }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        loginItemError = nil
        defer { loginItemStatus = service.status }

        let registered = service.status == .enabled || service.status == .requiresApproval
        guard enabled != registered else { return }
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            if !enabled || service.status != .requiresApproval {
                loginItemError = error.localizedDescription
            }
        }
    }
}
