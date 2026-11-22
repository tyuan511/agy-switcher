import AppKit
import Observation

@MainActor
@Observable
final class AppUpdater {
    enum Activity {
        case checking, installing
    }

    #if AGY_RELEASE_BUILD
    let enabled = true
    #else
    let enabled = false
    #endif

    let currentVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        .flatMap(ReleaseVersion.init)
    private(set) var activity: Activity?
    private(set) var update: GitHubRelease?
    private(set) var checked = false
    private(set) var error: (any Error)?
    private(set) var hasToken = false

    @ObservationIgnored private let client = GitHubReleaseClient()
    @ObservationIgnored private let credentials = KeychainCredentialStore(service: "dev.fastvibe.agy-switch.updates")
    private static let tokenAccount = "github-release-token"

    func start() {
        guard enabled else { return }
        hasToken = (try? credentials.read(Self.tokenAccount)) != nil
        if CommandLine.arguments.contains(UpdateInstaller.failureArgument) {
            error = UpdateError.installationFailed
        }
        Task {
            while !Task.isCancelled {
                await check(interactive: false)
                do {
                    try await Task.sleep(for: .seconds(86_400))
                } catch {
                    return
                }
            }
        }
    }

    func check(interactive: Bool = true) async {
        guard enabled, let currentVersion, activity == nil else { return }
        activity = .checking
        if interactive { error = nil }
        defer { activity = nil }
        do {
            update = try await client.latestUpdate(after: currentVersion, token: storedToken())
            checked = true
        } catch {
            if interactive { self.error = error }
        }
    }

    func saveToken(_ input: String) async {
        guard activity == nil else { return }
        let token = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.range(of: #"^[A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
            error = UpdateError.invalidToken
            return
        }
        do {
            try credentials.write(token.isEmpty ? nil : Data(token.utf8), account: Self.tokenAccount)
            hasToken = !token.isEmpty
            update = nil
            checked = false
            await check()
        } catch {
            self.error = error
        }
    }

    func install() async {
        guard enabled, activity == nil, let update else { return }
        activity = .installing
        error = nil
        defer { activity = nil }
        do {
            let installed = Bundle.main.bundleURL.resolvingSymlinksInPath()
            let token = try storedToken()
            let client = client
            let staged = try await Task.detached {
                let download = try await client.download(update, token: token)
                defer { try? FileManager.default.removeItem(at: download) }
                return try UpdateInstaller.stage(download, version: update.version, replacing: installed)
            }.value
            do {
                try UpdateInstaller.startInstaller(from: staged, replacing: installed)
            } catch {
                try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
                throw error
            }
            NSApplication.shared.terminate(nil)
        } catch {
            self.error = error
        }
    }

    private func storedToken() throws -> String? {
        try credentials.read(Self.tokenAccount).flatMap { String(data: $0, encoding: .utf8) }
    }
}
