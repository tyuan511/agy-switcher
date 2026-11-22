import SwiftUI

struct AccountsWindow: View {
    let model: AccountsModel
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.appLanguage) private var language
    @State private var removal: Account?

    var body: some View {
        VStack(spacing: 0) {
            if let message = model.message {
                MessageBar(text: message, symbol: "exclamationmark.circle", dismiss: model.dismissMessage)
            } else if let status = model.switchNotice ?? model.activeDescription, !model.accounts.isEmpty {
                MessageBar(text: status, symbol: "info.circle")
            }

            if !model.loaded {
                if model.message == nil {
                    ProgressView(language.text("正在读取账号…")).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Button(language.text("重试")) { model.refresh() }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if model.accounts.isEmpty {
                ContentUnavailableView {
                    Label(language.text("还没有账号"), systemImage: "person.crop.circle")
                } description: {
                    Text(language.text("添加 Google 账号以查看 Antigravity 和 agy 的配额。"))
                } actions: {
                    Button(language.text("添加账号"), systemImage: "plus") { model.add() }
                        .buttonStyle(.glass)
                        .disabled(model.changing)
                }
            } else {
                List {
                    ForEach(model.accounts) { account in
                        AccountQuota(model: model, account: account) { removal = account }
                            .padding(.vertical, 10)
                    }
                }
                .listStyle(.inset)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(language.text("刷新配额"), systemImage: "arrow.clockwise") { model.refresh() }
                    .labelStyle(.iconOnly)
                    .disabled(model.accounts.isEmpty || !model.refreshing.isEmpty)
                    .help(language.text("刷新所有账号的配额"))
                Button(language.text("添加账号"), systemImage: "plus") { model.add() }
                    .labelStyle(.iconOnly)
                    .disabled(!model.loaded || model.changing)
                    .help(language.text("添加账号"))
            }
        }
        .task { await model.surfaceOpened() }
        .onChange(of: appearsActive) { _, active in
            if active { Task { await model.surfaceOpened() } }
        }
        .confirmationDialog(language.text("移除账号？"), isPresented: Binding(get: { removal != nil }, set: { shown in
            if !shown { removal = nil }
        }), titleVisibility: .visible, presenting: removal) { account in
            Button(language.text("移除账号"), role: .destructive) { model.remove(account) }
        } message: { account in
            Text(language.text("从 AGY Switcher 移除 \(account.identity.email) 及其本地配额记录。客户端登录状态由 Antigravity 和 agy 管理。"))
        }
    }
}
