import AppKit
import SwiftUI

struct AccountsMenu: View {
    let model: AccountsModel
    let runsWithoutDock: Bool
    let updateTag: String?
    let showPage: (WindowPage) -> Void
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.appLanguage) private var language
    @State private var contentHeight: CGFloat = 64

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.accounts.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(model.activeDescription ?? language.text(model.loaded ? "请添加账号" : "正在读取账号…"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            if model.loaded {
                                Button(language.text("添加账号"), systemImage: "plus") {
                                    showPage(.accounts)
                                    model.add()
                                }
                                .buttonStyle(.glass)
                                .controlSize(.small)
                                .disabled(model.changing)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    ForEach(model.accounts) { account in
                        let isCurrent = model.active == .managed(account.id)
                        AccountQuota(model: model, account: account)
                            .padding(12)
                            .background(
                                isCurrent ? Color.accentColor.opacity(0.07) : Color.primary.opacity(0.03),
                                in: RoundedRectangle(cornerRadius: 11)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 11)
                                    .strokeBorder(
                                        isCurrent ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.07)
                                    )
                                    .allowsHitTesting(false)
                            }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollIndicators(.never)
            .defaultScrollAnchor(.top)
            .frame(height: min(440, contentHeight))

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
            } else if let notice = model.switchNotice {
                MessageBar(text: notice, symbol: "checkmark.circle.fill", tone: .info)
            }

            if let updateTag {
                Button {
                    showPage(.settings)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(.tint)
                        Text(language.text("可更新至 \(updateTag)"))
                            .font(.caption.weight(.medium))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(Color.accentColor.opacity(0.22))
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
            }
            Divider()
            HStack {
                Button(language.text("刷新配额"), systemImage: "arrow.clockwise") { model.refresh() }
                    .buttonStyle(.glass)
                    .disabled(model.accounts.isEmpty || !model.refreshing.isEmpty)
                Spacer()
                Button(language.text("打开窗口"), systemImage: "arrow.up.right.square") {
                    showPage(.accounts)
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
