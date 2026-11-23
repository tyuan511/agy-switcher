import SwiftUI

enum WindowPage: CaseIterable {
    case accounts, usage, settings

    var title: String.LocalizationValue {
        switch self {
        case .accounts: "账号管理"
        case .usage: "用量"
        case .settings: "设置"
        }
    }

    var symbol: String {
        switch self {
        case .accounts: "person.crop.circle"
        case .usage: "chart.bar.xaxis"
        case .settings: "gearshape"
        }
    }
}

struct MainWindow: View {
    let model: AccountsModel
    let updater: AppUpdater
    @Binding var page: WindowPage
    @Environment(\.appLanguage) private var language

    var body: some View {
        NavigationSplitView {
            List(WindowPage.allCases, id: \.self, selection: $page) { item in
                HStack {
                    Label(language.text(item.title), systemImage: item.symbol)
                    if item == .settings, updater.update != nil {
                        Spacer()
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 150, ideal: 166, max: 210)
        } detail: {
            Group {
                switch page {
                case .accounts: AccountsWindow(model: model)
                case .usage: UsagePage()
                case .settings:
                    SettingsPage(preferences: model.preferences, updater: updater, model: model)
                }
            }
            .navigationTitle(language.text(page.title))
            .frame(minWidth: 400, minHeight: 380)
        }
        .sheet(isPresented: Binding(get: { model.authorizing }, set: { presented in
            if !presented { model.cancelAuthorization() }
        })) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "person.badge.key.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text(language.text("正在等待 Google 授权"))
                        .font(.headline)
                }
                Text(language.text("在默认浏览器中选择账号并完成授权。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    ProgressView().controlSize(.small)
                    Spacer()
                    Button(language.text("取消"), role: .cancel) { model.cancelAuthorization() }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.top, 4)
            }
            .padding(24)
            .frame(width: 360)
        }
    }
}
