import AppKit
import Darwin

@MainActor
enum AntigravityApplication {
    struct StoppedInstance: Sendable {
        let url: URL
        let previousPIDs: Set<pid_t>
    }

    private static let bundleIdentifier = "com.google.antigravity"

    static func stopIfRunning() async throws -> StoppedInstance? {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { processIsRunning($0.processIdentifier) }
        guard !applications.isEmpty else { return nil }
        let previousPIDs = Set(applications.map(\.processIdentifier))

        let workspace = NSWorkspace.shared
        guard let url = applications.compactMap(\.bundleURL).first
            ?? workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            throw AGYError.antigravityApplicationUnavailable
        }

        let trackedPIDs = previousPIDs.union(bundleProcessIDs(inside: url))
        for application in applications where processIsRunning(application.processIdentifier) {
            guard application.terminate() || !processIsRunning(application.processIdentifier) else {
                throw AGYError.antigravityQuitFailed
            }
        }

        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(15)
        while trackedPIDs.contains(where: processIsRunning) || !bundleProcessIDs(inside: url).isEmpty {
            guard clock.now < deadline else { throw AGYError.antigravityQuitTimedOut }
            try await Task.sleep(for: .milliseconds(100))
        }
        return StoppedInstance(url: url, previousPIDs: previousPIDs)
    }

    static func relaunch(_ stopped: StoppedInstance) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        // Launch Services can retain the exited app's registration while a helper is still running.
        configuration.createsNewApplicationInstance = true
        let relaunched = try await NSWorkspace.shared.openApplication(at: stopped.url, configuration: configuration)
        let pid = relaunched.processIdentifier
        guard !stopped.previousPIDs.contains(pid), processIsRunning(pid) else {
            throw AGYError.antigravityLaunchFailed
        }
    }

    private static func bundleProcessIDs(inside bundleURL: URL) -> Set<pid_t> {
        let prefix = bundleURL.standardizedFileURL.path + "/"
        let estimated = proc_listallpids(nil, 0)
        guard estimated > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimated) * 2)
        let bytesReturned = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard bytesReturned > 0 else { return [] }
        let count = Int(bytesReturned) / MemoryLayout<pid_t>.stride

        var result = Set<pid_t>()
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        for pid in pids.prefix(count) where pid > 0 {
            let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            guard length > 0 else { continue }
            let path = String(decoding: pathBuffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if path.hasPrefix(prefix) && processIsRunning(pid) {
                result.insert(pid)
            }
        }
        return result
    }

    private static func processIsRunning(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
