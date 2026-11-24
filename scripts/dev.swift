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

func capture(_ executable: String, _ arguments: [String]) -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    } catch {
        return nil
    }
}

func findSigningIdentity(teamID: String) -> String? {
    guard let data = capture("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"]),
          let output = String(data: data, encoding: .utf8) else { return nil }
    for line in output.split(separator: "\n") {
        guard line.contains("Developer ID Application:"), line.contains("(\(teamID))") else { continue }
        let parts = line.split(whereSeparator: \.isWhitespace)
        if parts.count >= 2, parts[1].count == 40 {
            return String(parts[1])
        }
    }
    return nil
}

func findProvisioningProfile(appIdentifier: String) -> URL? {
    let files = FileManager.default
    if let explicit = ProcessInfo.processInfo.environment["AGY_PROVISIONING_PROFILE"], !explicit.isEmpty {
        let url = URL(filePath: explicit)
        if files.fileExists(atPath: url.path) { return url }
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
    let directories = [
        home.appending(path: "Library/Developer/Xcode/UserData/Provisioning Profiles", directoryHint: .isDirectory),
        home.appending(path: "Library/MobileDevice/Provisioning Profiles", directoryHint: .isDirectory),
    ]
    for directory in directories {
        guard let entries = try? files.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { continue }
        for url in entries where url.pathExtension == "provisionprofile" {
            guard let xml = capture("/usr/bin/security", ["cms", "-D", "-i", url.path]),
                  let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any],
                  let entitlements = plist["Entitlements"] as? [String: Any],
                  entitlements["com.apple.application-identifier"] as? String == appIdentifier else {
                continue
            }
            return url
        }
    }
    return nil
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

    let entitlements = root.appending(path: "Config/AGYSwitcher.entitlements")
    if let profile = findProvisioningProfile(appIdentifier: "J24Y9W38D8.dev.fastvibe.agy-switch") {
        guard let identity = findSigningIdentity(teamID: "J24Y9W38D8") else {
            throw DevelopmentError("Could not find a Developer ID Application signing identity for team J24Y9W38D8.")
        }
        let embeddedProfile = stagedApp.appending(path: "Contents/embedded.provisionprofile")
        try? files.removeItem(at: embeddedProfile)
        try files.copyItem(at: profile, to: embeddedProfile)
        try run("/usr/bin/codesign", [
            "--force", "--sign", identity,
            "--timestamp=none", "--options", "runtime",
            "--entitlements", entitlements.path,
            "--generate-entitlement-der",
            stagedApp.path,
        ])
        print("Embedded Developer ID provisioning profile (Data Protection Keychain enabled).")
    } else {
        print("Note: No Developer ID provisioning profile found; running without Data Protection Keychain.")
    }

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
