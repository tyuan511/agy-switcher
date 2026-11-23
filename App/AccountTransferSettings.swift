import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AccountTransferSettings: View {
    let model: AccountsModel
    @Environment(\.appLanguage) private var language
    @State private var showingExportPassphrase = false
    @State private var importRequest: ImportRequest?
    @State private var message: String?

    struct ImportRequest: Identifiable {
        let url: URL
        var id: String { url.path }
    }

    static let backupType = UTType(filenameExtension: AccountBackup.fileExtension) ?? .data

    var body: some View {
        Section(language.text("导出与导入")) {
            LabeledContent {
                Button(language.text("导出…")) {
                    message = nil
                    showingExportPassphrase = true
                }
                .disabled(model.changing)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(language.text("导出账号"))
                    Text(language.text("将全部账号与登录凭据导出为密码加密的备份文件。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent {
                Button(language.text("导入…")) {
                    message = nil
                    chooseImportFile()
                }
                .disabled(model.changing)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(language.text("导入账号"))
                    Text(language.text("从备份文件导入账号，已存在的账号保持不变。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let message {
                Text(message).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showingExportPassphrase) {
            ExportBackupSheet(model: model) { result in
                showingExportPassphrase = false
                message = result
            }
        }
        .sheet(item: $importRequest) { request in
            ImportBackupSheet(model: model, url: request.url) { result in
                importRequest = nil
                message = result
            }
        }
    }

    private func chooseImportFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.backupType]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = language.text("选择要导入的备份文件。")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            importRequest = ImportRequest(url: url)
        }
    }
}

private struct ExportBackupSheet: View {
    let model: AccountsModel
    let completion: (String) -> Void
    @Environment(\.appLanguage) private var language
    @Environment(\.dismiss) private var dismiss
    @State private var passphrase = ""
    @State private var repeated = ""
    @State private var working = false
    @State private var error: String?

    private var mismatch: Bool { !repeated.isEmpty && repeated != passphrase }
    private var ready: Bool { !passphrase.isEmpty && !mismatch && !working }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(language.text("设置备份密码")).font(.headline)
            Text(language.text("备份文件包含所有账号的登录凭据，将使用密码加密。导入时需要输入相同密码。"))
                .foregroundStyle(.secondary)
            SecureField(language.text("密码"), text: $passphrase)
            SecureField(language.text("确认密码"), text: $repeated)
            if mismatch {
                Text(language.text("两次输入的密码不一致。")).foregroundStyle(.red)
            } else if let error {
                Text(error).foregroundStyle(.red)
            }
            HStack {
                if working {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button(language.text("取消"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(language.text("导出")) { chooseDestination() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [AccountTransferSettings.backupType]
        panel.nameFieldStringValue = language.text("AGY 账号备份")
        panel.message = language.text("备份文件以密码加密，包含全部账号凭据。")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            export(to: url)
        }
    }

    private func export(to url: URL) {
        working = true
        error = nil
        Task { @MainActor in
            do {
                let count = try await model.exportBackup(to: url, passphrase: passphrase)
                dismiss()
                completion(language.text("已导出 \(count) 个账号。"))
            } catch {
                working = false
                self.error = language.errorDescription(error)
            }
        }
    }
}

private struct ImportBackupSheet: View {
    let model: AccountsModel
    let url: URL
    let completion: (String) -> Void
    @Environment(\.appLanguage) private var language
    @Environment(\.dismiss) private var dismiss
    @State private var passphrase = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(language.text("输入备份密码")).font(.headline)
            Text(language.text("将导入 \(url.lastPathComponent) 中的账号，已存在的账号保持不变。"))
                .foregroundStyle(.secondary)
            SecureField(language.text("密码"), text: $passphrase)
                .onSubmit { if ready { importBackup() } }
            if working {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(language.text("正在导入账号…")).foregroundStyle(.secondary)
                }
            } else if let error {
                Text(error).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(language.text("取消"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(language.text("导入")) { importBackup() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    private var ready: Bool { !passphrase.isEmpty && !working }

    private func importBackup() {
        working = true
        error = nil
        Task { @MainActor in
            do {
                let summary = try await model.importBackup(from: url, passphrase: passphrase)
                dismiss()
                if summary.skipped > 0 {
                    completion(language.text("已导入 \(summary.imported) 个账号，跳过 \(summary.skipped) 个已存在的账号。"))
                } else {
                    completion(language.text("已导入 \(summary.imported) 个账号。"))
                }
            } catch {
                working = false
                self.error = language.errorDescription(error)
            }
        }
    }
}
