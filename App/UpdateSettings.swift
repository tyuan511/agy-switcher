import SwiftUI

struct UpdateSettings: View {
    let updater: AppUpdater
    @Environment(\.appLanguage) private var language

    var body: some View {
        Section(language.text("软件更新")) {
            LabeledContent {
                Button(language.text("检查更新")) { Task { await updater.check() } }
                    .disabled(updater.activity != nil)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(language.text("版本更新"))
                    Text(language.text("当前版本 \(updater.currentVersion?.description ?? "—")"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let activity = updater.activity {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(language.text(activity == .checking ? "正在检查更新…" : "正在下载并验证更新…"))
                        .foregroundStyle(.secondary)
                }
            } else if let error = updater.error {
                Label(
                    (error as? UpdateError).map { language.text($0.message) } ?? language.errorDescription(error),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.red)
            } else if updater.update == nil && updater.checked {
                Label(language.text("暂无新版可用。"), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let update = updater.update {
                LabeledContent(language.text("可用版本"), value: update.tag)
                Link(language.text("查看更新说明"), destination: update.notesURL(language: language))
                Button(language.text("下载并重启")) { Task { await updater.install() } }
                    .buttonStyle(.glassProminent)
                    .disabled(updater.activity != nil)
            }
        }
    }
}
