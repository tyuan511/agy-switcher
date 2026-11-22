import AppKit
import Darwin

@MainActor
enum AntigravityApplication {
    private static let bundleIdentifier = "com.google.antigravity"

    static func restartIfRunning() async throws -> Bool {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { processIsRunning($0.processIdentifier) }
        guard !applications.isEmpty else { return false }
        let previousPIDs = Set(applications.map(\.processIdentifier))

        let workspace = NSWorkspace.shared
        guard let url = applications.compactMap(\.bundleURL).first
            ?? workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            throw AGYError.antigravityApplicationUnavailable
        }

        for application in applications where processIsRunning(application.processIdentifier) {
            guard application.terminate() || !processIsRunning(application.processIdentifier) else {
                throw AGYError.antigravityQuitFailed
            }
        }

        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(15)
        while previousPIDs.contains(where: processIsRunning) {
            guard clock.now < deadline else { throw AGYError.antigravityQuitTimedOut }
            try await Task.sleep(for: .milliseconds(100))
        }

        let configuration = NSWorkspace.OpenConfiguration()
        // Launch Services can retain the exited app's registration while a helper is still running.
        configuration.createsNewApplicationInstance = true
        let relaunched = try await workspace.openApplication(at: url, configuration: configuration)
        let pid = relaunched.processIdentifier
        guard !previousPIDs.contains(pid), processIsRunning(pid) else {
            throw AGYError.antigravityLaunchFailed
        }
        return true
    }

    private static func processIsRunning(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
