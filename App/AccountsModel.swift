import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AccountsModel {
    private enum FailedOperation {
        case readAccounts, addAccount, reauthorize, switchAccount, restartAntigravity, removeAccount, readActiveAccount
    }

    private enum SwitchOutcome {
        case credentialsUpdated, antigravityRestarted
    }

    let preferences = AppPreferences()
    private(set) var accounts: [Account] = []
    private(set) var active: ActiveAccount = .unknown
    private(set) var loaded = false
    private(set) var authorizing = false
    private(set) var switching: String?
    private(set) var removing = false
    private(set) var refreshing: Set<String> = []
    private(set) var quotaErrors: [String: any Error] = [:]
    private(set) var needsAuthorization: Set<String> = []

    private let service: AccountService
    private var switchOutcome: SwitchOutcome?
    @ObservationIgnored private var switchNoticeTask: Task<Void, Never>?
    private var failure: (operation: FailedOperation, error: any Error)?
    private var opening = false
    private var lastActiveRead: Date?
    private var activeReadVersion = 0
    private var lastQuotaAttempts: [String: Date] = [:]
    private var refreshQueue: [String] = []
    private var runningRefreshes = 0
    private var authorizationTask: Task<Void, Never>?

    init() {
        let folder = URL.applicationSupportDirectory.appendingPathComponent("AGY Switcher", isDirectory: true)
        let antigravity = Bundle(url: URL(filePath: "/Applications/Antigravity.app", directoryHint: .isDirectory))
        let version = antigravity?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.34.0"
        service = AccountService(repository: .init(directory: folder), quota: .init(version: version))
    }

    var changing: Bool { authorizing || switching != nil || removing }

    var currentAccount: Account? {
        guard case .managed(let id) = active else { return nil }
        return accounts.first { $0.id == id }
    }

    var activeDescription: String? {
        let language = preferences.language
        switch active {
        case .unknown, .managed: return nil
        case .signedOut: return language.text("Antigravity 与 agy 尚未登录。")
        case .unmanaged: return language.text("客户端当前登录的账号尚未添加。")
        case .inconsistent: return language.text("客户端凭据不一致，可重新切换到同一账号。")
        }
    }

    var switchNotice: String? {
        let language = preferences.language
        switch switchOutcome {
        case .credentialsUpdated: return language.text("共享账号已切换。下次启动客户端时将使用新账号。")
        case .antigravityRestarted: return language.text("共享账号已切换，Antigravity 已重启。")
        case nil: return nil
        }
    }

    var message: String? {
        guard let failure else { return nil }
        let language = preferences.language
        let detail = language.errorDescription(failure.error)
        switch failure.operation {
        case .readAccounts: return language.text("无法读取本地账号。\(detail)")
        case .addAccount: return language.text("添加账号失败。\(detail)")
        case .reauthorize: return language.text("重新授权失败。\(detail)")
        case .switchAccount: return language.text("切换失败。\(detail)")
        case .restartAntigravity: return language.text("共享账号已切换。请手动重启 Antigravity。\(detail)")
        case .removeAccount: return language.text("移除失败。\(detail)")
        case .readActiveAccount: return language.text("无法读取客户端登录状态。\(detail)")
        }
    }

    func dismissMessage() { failure = nil }

    func surfaceOpened() async {
        guard !opening, !changing else { return }
        opening = true
        defer { opening = false }
        if !loaded {
            do {
                accounts = try await service.list()
                loaded = true
            } catch {
                failure = (.readAccounts, error)
                return
            }
        }
        if lastActiveRead?.timeIntervalSinceNow ?? -.infinity < -5 {
            await readActiveAccount()
        }

        guard preferences.automaticallyRefreshQuota else { return }
        let interval = preferences.quotaRefreshInterval
        let now = Date.now
        let stale = accounts.filter { account in
            let last = lastQuotaAttempts[account.id] ?? account.quota?.updatedAt
            return !needsAuthorization.contains(account.id) && interval.hasElapsed(since: last, at: now)
        }
        enqueueRefresh(stale.map(\.id))
    }

    func refresh(_ id: String? = nil) {
        Task {
            if !loaded {
                await surfaceOpened()
                return
            }
            enqueueRefresh(id.map { [$0] } ?? accounts.map(\.id))
            if !changing { await readActiveAccount() }
        }
    }

    func add(_ account: Account? = nil) {
        guard loaded, !changing else { return }
        if let account, refreshing.contains(account.id) { return }
        dismissMessage()
        authorizing = true
        authorizationTask = Task {
            defer {
                authorizing = false
                authorizationTask = nil
            }
            do {
                let added = try await service.authorize(account: account?.identity, language: preferences.language) { url in
                    NSWorkspace.shared.open(url)
                }
                upsert(added)
                needsAuthorization.remove(added.id)
                await readActiveAccount()
                enqueueRefresh([added.id])
            } catch is CancellationError {
                // Cancellation is exposed by the authorization sheet.
            } catch {
                if !Task.isCancelled {
                    failure = (account == nil ? .addAccount : .reauthorize, error)
                }
            }
        }
    }

    func cancelAuthorization() { authorizationTask?.cancel() }

    func switchTo(_ account: Account) {
        guard !changing else { return }
        switching = account.id
        activeReadVersion += 1
        dismissMessage()
        setSwitchOutcome(nil)
        Task {
            defer { switching = nil }
            do {
                try await service.switchAccount(to: account.id)
            } catch {
                if error as? AGYError == .authenticationRequired { needsAuthorization.insert(account.id) }
                await readActiveAccount(reportError: false)
                failure = (.switchAccount, error)
                return
            }

            do {
                let restarted = try await AntigravityApplication.restartIfRunning()
                setSwitchOutcome(restarted ? .antigravityRestarted : .credentialsUpdated)
            } catch {
                setSwitchOutcome(.credentialsUpdated)
                failure = (.restartAntigravity, error)
            }
            active = .managed(account.id)
            lastActiveRead = .now
        }
    }

    func remove(_ account: Account) {
        guard !changing, !refreshing.contains(account.id) else { return }
        removing = true
        Task {
            defer { removing = false }
            do {
                try await service.remove(account.id)
                accounts.removeAll { $0.id == account.id }
                needsAuthorization.remove(account.id)
                quotaErrors[account.id] = nil
                lastQuotaAttempts[account.id] = nil
                await readActiveAccount()
            } catch {
                failure = (.removeAccount, error)
            }
        }
    }

    private func setSwitchOutcome(_ outcome: SwitchOutcome?) {
        switchNoticeTask?.cancel()
        switchNoticeTask = nil
        switchOutcome = outcome
        guard outcome != nil else { return }

        switchNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            self.switchOutcome = nil
            self.switchNoticeTask = nil
        }
    }

    private func readActiveAccount(reportError: Bool = true) async {
        activeReadVersion += 1
        let version = activeReadVersion
        lastActiveRead = .now
        do {
            let result = try await service.activeAccount()
            guard version == activeReadVersion else { return }
            if active != result { setSwitchOutcome(nil) }
            active = result
        } catch {
            guard version == activeReadVersion else { return }
            active = .unknown
            if reportError { failure = (.readActiveAccount, error) }
        }
    }

    private func enqueueRefresh(_ ids: [String]) {
        for id in ids where refreshing.insert(id).inserted {
            refreshQueue.append(id)
        }
        startReadyRefreshes()
    }

    private func startReadyRefreshes() {
        while runningRefreshes < 3, !refreshQueue.isEmpty {
            let id = refreshQueue.removeFirst()
            runningRefreshes += 1
            lastQuotaAttempts[id] = .now
            Task {
                defer {
                    refreshing.remove(id)
                    runningRefreshes -= 1
                    startReadyRefreshes()
                }
                do {
                    upsert(try await service.refreshQuota(for: id))
                    needsAuthorization.remove(id)
                    quotaErrors[id] = nil
                } catch {
                    if error as? AGYError == .authenticationRequired { needsAuthorization.insert(id) }
                    quotaErrors[id] = error
                }
            }
        }
    }

    private func upsert(_ account: Account) {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
    }
}
