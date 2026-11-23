import SwiftUI

struct AccountsWindow: View {
    let model: AccountsModel
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.appLanguage) private var language
    @State private var removal: Account?

    var body: some View {
        Group {
            if !model.loaded {
                VStack(spacing: 12) {
                    if let message = model.message {
                        MessageBar(text: message, symbol: "exclamationmark.circle.fill", tone: .error, dismiss: model.dismissMessage)
                            .padding(.horizontal, 22)
                            .padding(.top, 16)
                        Button(language.text("重试")) { model.refresh() }
                            .buttonStyle(.glass)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ProgressView(language.text("正在读取账号…"))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else if model.accounts.isEmpty {
                VStack(spacing: 0) {
                    if model.message != nil || model.keychainPermissionRequired {
                        banner
                            .padding(.horizontal, 22)
                            .padding(.top, 16)
                    }
                    ContentUnavailableView {
                        Label(language.text("还没有账号"), systemImage: "person.crop.circle")
                    } description: {
                        Text(language.text("添加 Google 账号以查看 Antigravity 和 agy 的配额。"))
                    } actions: {
                        Button(language.text("添加账号"), systemImage: "plus") { model.add() }
                            .buttonStyle(.glass)
                            .disabled(model.changing)
                    }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        banner
                        ForEach(model.accounts) { account in
                            let isCurrent = model.active == .managed(account.id)
                            AccountQuota(model: model, account: account) { removal = account }
                                .padding(16)
                                .background(
                                    isCurrent ? AnyShapeStyle(Color.accentColor.opacity(0.055)) : AnyShapeStyle(.background),
                                    in: RoundedRectangle(cornerRadius: 14)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 14)
                                        .strokeBorder(
                                            isCurrent ? AnyShapeStyle(Color.accentColor.opacity(0.28)) : AnyShapeStyle(.quaternary)
                                        )
                                        .allowsHitTesting(false)
                                }
                        }
                    }
                    .padding(22)
                    .frame(maxWidth: 1_050)
                    .frame(maxWidth: .infinity)
                }
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

    @ViewBuilder
    private var banner: some View {
        if let message = model.message {
            MessageBar(text: message, symbol: "exclamationmark.circle.fill", tone: .error, dismiss: model.dismissMessage)
        } else if model.keychainPermissionRequired {
            MessageBar(
                text: language.text("需要钥匙串权限以自动刷新配额。请在弹窗中选择「始终允许」。"),
                symbol: "key.fill",
                tone: .warning,
                actionTitle: language.text("授权"),
                action: { model.refresh() }
            )
        } else if let status = model.switchNotice ?? model.activeDescription, !model.accounts.isEmpty {
            MessageBar(text: status, symbol: "info.circle.fill", tone: .info)
        }
    }
}
