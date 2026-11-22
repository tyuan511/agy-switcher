import AppKit
import SwiftUI

struct AccountsMenu: View {
    let model: AccountsModel
    let runsWithoutDock: Bool
    let updateTag: String?
    let showPage: (WindowPage) -> Void
    @Environment(\.openWindow) private var openWindow
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.appLanguage) private var language
    @State private var contentHeight: CGFloat = 64

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let account = model.currentAccount {
                        AccountQuota(model: model, account: account)
                    } else if model.accounts.isEmpty {
                        Text(model.activeDescription ?? language.text(model.loaded ? "请添加账号" : "正在读取账号…"))
                            .foregroundStyle(.secondary)
                    }

                    let others = model.accounts.filter { $0.id != model.currentAccount?.id }
                    ForEach(others) { account in
                        if model.currentAccount != nil || account.id != others.first?.id { Divider() }
                        AccountQuota(model: model, account: account)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollIndicators(.never)
            .defaultScrollAnchor(.top)
            .frame(height: min(440, contentHeight))

            if let message = model.message {
                MessageBar(text: message, symbol: "exclamationmark.circle", dismiss: model.dismissMessage)
            } else if let notice = model.switchNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }

            if let updateTag {
                Button(language.text("可更新至 \(updateTag)"), systemImage: "arrow.down.circle") {
                    showPage(.settings)
                    openWindow(id: "accounts")
                    NSApplication.shared.activate()
                }
            }
            Divider()
            HStack {
                Button(language.text("刷新配额"), systemImage: "arrow.clockwise") { model.refresh() }
                    .buttonStyle(.glass)
                    .disabled(model.accounts.isEmpty || !model.refreshing.isEmpty)
                Spacer()
                Button(language.text("打开窗口"), systemImage: "person.crop.circle") {
                    showPage(.accounts)
                    openWindow(id: "accounts")
                    NSApplication.shared.activate()
                }
                .buttonStyle(.glass)
                if runsWithoutDock {
                    Button(language.text("退出应用"), systemImage: "power") {
                        NSApplication.shared.terminate(nil)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .help(language.text("退出应用"))
                }
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 370)
        .task { await model.surfaceOpened() }
        .onChange(of: appearsActive) { _, active in
            if active { Task { await model.surfaceOpened() } }
        }
    }
}
