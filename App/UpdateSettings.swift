import SwiftUI

struct UpdateSettings: View {
    let updater: AppUpdater
    @Environment(\.appLanguage) private var language
    @State private var token = ""

    var body: some View {
        Section(language.text("软件更新")) {
            LabeledContent(language.text("当前版本"), value: updater.currentVersion?.description ?? "—")
            if let activity = updater.activity {
                ProgressView(language.text(activity == .checking ? "正在检查更新…" : "正在下载并验证更新…"))
            } else if let error = updater.error {
                Text((error as? UpdateError).map { language.text($0.message) } ?? language.errorDescription(error))
                    .foregroundStyle(.secondary)
            } else if updater.update == nil && updater.checked {
                Text(language.text("暂无新版可用。")).foregroundStyle(.secondary)
            }
            if let update = updater.update {
                LabeledContent(language.text("可用版本"), value: update.tag)
                Link(language.text("查看更新说明"), destination: update.notesURL(language: language))
                Button(language.text("下载并重启")) { Task { await updater.install() } }
                    .disabled(updater.activity != nil)
            }
            Button(language.text("检查更新")) { Task { await updater.check() } }
                .disabled(updater.activity != nil)
        }
        Section {
            SecureField(language.text("GitHub 读取令牌"), text: $token)
                .disabled(updater.activity != nil)
            HStack {
                Button(language.text("保存令牌")) {
                    let input = token
                    token = ""
                    Task { await updater.saveToken(input) }
                }
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || updater.activity != nil)
                if updater.hasToken {
                    Button(language.text("移除已保存的令牌")) { Task { await updater.saveToken("") } }
                        .disabled(updater.activity != nil)
                }
            }
        } header: {
            Text(language.text("私有仓库访问"))
        } footer: {
            Text(language.text("为 AGY Switcher 仓库授予 Contents 只读权限。令牌保存在本机钥匙串。"))
        }
    }
}
