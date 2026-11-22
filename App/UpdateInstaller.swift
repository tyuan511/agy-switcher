import Darwin
import Foundation

enum UpdateInstaller {
    static let installArgument = "--agy-install-update"
    static let failureArgument = "--agy-update-failed"

    private static let appName = "AGY Switcher.app"
    private static let bundleID = "dev.fastvibe.agy-switch"
    private static let stagingPrefix = ".agy-switcher-update-"
    private static let signer = """
        anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists
        and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "J24Y9W38D8"
        """

    static func stage(_ download: URL, version: ReleaseVersion, replacing installed: URL) throws -> URL {
        let files = FileManager.default
        // Keep the staged app on the installation volume for the atomic swap.
        let staging = installed.deletingLastPathComponent().appendingPathComponent(stagingPrefix + UUID().uuidString)
        do {
            try files.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            throw UpdateError.installationLocation
        }
        do {
            let work = files.temporaryDirectory.appendingPathComponent(staging.lastPathComponent)
            try files.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? files.removeItem(at: work) }
            let image = work.appendingPathComponent("update.dmg")
            try files.moveItem(at: download, to: image)
            try verifySignature(of: image, requirement: signer)
            try verifyNotarization(of: image)

            let mount = work.appendingPathComponent("mounted")
            try files.createDirectory(at: mount, withIntermediateDirectories: false)
            try run("/usr/bin/hdiutil", ["attach", image.path, "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path])
            defer {
                if (try? run("/usr/bin/hdiutil", ["detach", mount.path])) == nil {
                    _ = try? run("/usr/bin/hdiutil", ["detach", "-force", mount.path])
                }
            }
            let source = mount.appendingPathComponent(appName)
            let bundledApp = staging.appendingPathComponent(appName)
            guard source.resolvingSymlinksInPath().path == mount.resolvingSymlinksInPath().appendingPathComponent(appName).path else {
                throw UpdateError.invalidSignature
            }
            try run("/usr/bin/ditto", [source.path, bundledApp.path])
            guard try verifiedAppVersion(bundledApp) == version else { throw UpdateError.invalidSignature }
            return bundledApp
        } catch {
            try? files.removeItem(at: staging)
            throw error
        }
    }

    static func startInstaller(from staged: URL, replacing installed: URL) throws {
        let process = Process()
        guard let executable = Bundle(url: staged)?.executableURL else { throw UpdateError.invalidSignature }
        process.executableURL = executable
        process.arguments = [installArgument, installed.path, String(getpid())]
        try process.run()
    }

    // The staged, signed app runs this entry point after the old app has exited.
    static func finish(arguments: [String]) {
        guard arguments.count == 2, let parent = Int32(arguments[1]), parent > 1,
              getppid() == parent || getppid() == 1 else { return }
        let installed = URL(fileURLWithPath: arguments[0]).resolvingSymlinksInPath()
        let staged = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let staging = staged.deletingLastPathComponent()
        let name = staging.lastPathComponent
        guard staged.lastPathComponent == appName, name.hasPrefix(stagingPrefix),
              UUID(uuidString: String(name.dropFirst(stagingPrefix.count))) != nil,
              staging.deletingLastPathComponent().path == installed.deletingLastPathComponent().path else { return }

        var removeStaging = true
        defer {
            if removeStaging { try? FileManager.default.removeItem(at: staging) }
        }
        do {
            try waitForExit(parent)
        } catch {
            return
        }
        do {
            guard try verifiedAppVersion(staged) > verifiedAppVersion(installed) else {
                throw UpdateError.invalidSignature
            }
            try swap(staged, installed)
            do {
                try run("/usr/bin/open", ["-n", installed.path])
            } catch {
                // Preserve the previous bundle for recovery if even the rollback fails.
                removeStaging = false
                try swap(staged, installed)
                removeStaging = true
                throw error
            }
        } catch {
            NSLog("AGY Switcher update failed: %@", String(describing: error))
            let recoverableApp = removeStaging ? installed : staged
            if (try? verifiedAppVersion(recoverableApp)) != nil {
                _ = try? run("/usr/bin/open", ["-n", recoverableApp.path, "--args", failureArgument])
            }
        }
    }

    private static func verifiedAppVersion(_ url: URL) throws -> ReleaseVersion {
        try verifySignature(of: url, requirement: signer + " and identifier \"\(bundleID)\"")
        guard let bundle = Bundle(url: url), bundle.bundleIdentifier == bundleID,
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let release = ReleaseVersion(version) else { throw UpdateError.invalidSignature }
        return release
    }

    private static func verifySignature(of url: URL, requirement: String) throws {
        do {
            try run("/usr/bin/codesign", ["--verify", "--strict", "--deep", "-R=\(requirement)", url.path])
        } catch {
            throw UpdateError.invalidSignature
        }
    }

    private static func verifyNotarization(of image: URL) throws {
        let assessment = try? run("/usr/sbin/spctl", [
            "--assess", "--type", "open", "--context", "context:primary-signature", "--raw", image.path,
        ], captureOutput: true)
        guard let assessment,
              let result = try? PropertyListSerialization.propertyList(from: assessment, format: nil) as? [String: Any],
              result["assessment:verdict"] as? Bool == true,
              let authority = result["assessment:authority"] as? [String: Any],
              authority["assessment:authority:source"] as? String == "Notarized Developer ID" else {
            throw UpdateError.missingNotarization
        }
    }

    private static func waitForExit(_ pid: Int32) throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(20)
        while kill(pid, 0) == 0 || errno == EPERM {
            guard clock.now < deadline else { throw UpdateError.installationFailed }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private static func swap(_ first: URL, _ second: URL) throws {
        guard renameatx_np(AT_FDCWD, first.path, AT_FDCWD, second.path, UInt32(RENAME_SWAP)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String], captureOutput: Bool = false) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let output = captureOutput ? Pipe() : nil
        if let output {
            process.standardOutput = output
        } else {
            process.standardOutput = FileHandle.nullDevice
        }
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = try output?.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.installationFailed }
        return data
    }
}
