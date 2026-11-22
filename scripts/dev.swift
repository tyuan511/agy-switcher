#!/usr/bin/swift
import AppKit
import Darwin

struct DevelopmentError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw DevelopmentError("\(executable) exited with status \(process.terminationStatus).")
    }
}

@MainActor
func quitRunningApps(bundleIdentifier: String) async throws {
    let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
    for application in applications where !application.isTerminated {
        _ = application.terminate()
    }

    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(15)
    while applications.contains(where: { !$0.isTerminated }) {
        guard clock.now < deadline else {
            throw DevelopmentError("AGY Switcher did not quit within 15 seconds. Quit it and run the script again.")
        }
        try await Task.sleep(for: .milliseconds(100))
    }
}

@MainActor
func buildAndLaunch() async throws {
    let files = FileManager.default
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let derivedData = root.appending(path: "DerivedData", directoryHint: .isDirectory)
    let buildDirectory = derivedData.appending(path: "DevBuild", directoryHint: .isDirectory)
    let launchDirectory = derivedData.appending(path: "Build/Products/Debug", directoryHint: .isDirectory)
    let appName = "AGY Switcher.app"
    let launchApp = launchDirectory.appending(path: appName, directoryHint: .isDirectory)

    try files.createDirectory(at: launchDirectory, withIntermediateDirectories: true)
    let lockURL = derivedData.appending(path: ".dev.lock")
    let lock = open(lockURL.path, O_WRONLY | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard lock >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { _ = close(lock) }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
        if errno == EWOULDBLOCK {
            throw DevelopmentError("Another development launch is already in progress.")
        }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    print("Building and signing AGY Switcher…")
    try run("/usr/bin/xcodebuild", [
        "-project", root.appending(path: "AGYSwitcher.xcodeproj").path,
        "-scheme", "AGYSwitcher",
        "-configuration", "Debug",
        "-destination", "platform=macOS",
        "-derivedDataPath", derivedData.path,
        "CONFIGURATION_BUILD_DIR=\(buildDirectory.path)",
        "OTHER_CODE_SIGN_FLAGS=--timestamp=none",
        "build",
    ])

    // Stage on the same volume so the signed build can replace the app at its stable path.
    let staging = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: launchDirectory, create: true)
    defer { try? files.removeItem(at: staging) }
    let stagedApp = staging.appending(path: appName, directoryHint: .isDirectory)
    try run("/usr/bin/ditto", [buildDirectory.appending(path: appName).path, stagedApp.path])
    try run("/usr/bin/codesign", [
        "--verify", "--deep", "--strict",
        "-R=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists",
        stagedApp.path,
    ])
    guard let bundleIdentifier = Bundle(url: stagedApp)?.bundleIdentifier else {
        throw DevelopmentError("The signed build has no bundle identifier.")
    }

    try await quitRunningApps(bundleIdentifier: bundleIdentifier)
    if files.fileExists(atPath: launchApp.path) {
        _ = try files.replaceItemAt(launchApp, withItemAt: stagedApp, backupItemName: nil, options: .usingNewMetadataOnly)
    } else {
        try files.moveItem(at: stagedApp, to: launchApp)
    }

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    configuration.allowsRunningApplicationSubstitution = false
    _ = try await NSWorkspace.shared.openApplication(at: launchApp, configuration: configuration)
    print("Opened \(launchApp.path)")
}

do {
    try await buildAndLaunch()
} catch {
    FileHandle.standardError.write(Data("Development launch failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
