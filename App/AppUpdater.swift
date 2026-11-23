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

    @ObservationIgnored private let client = GitHubReleaseClient()

    func start() {
        guard enabled else { return }
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
            update = try await client.latestUpdate(after: currentVersion)
            checked = true
        } catch {
            if interactive { self.error = error }
        }
    }

    func install() async {
        guard enabled, activity == nil, let update else { return }
        activity = .installing
        error = nil
        defer { activity = nil }
        do {
            let installed = Bundle.main.bundleURL.resolvingSymlinksInPath()
            let client = client
            let staged = try await Task.detached {
                let download = try await client.download(update)
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
}
