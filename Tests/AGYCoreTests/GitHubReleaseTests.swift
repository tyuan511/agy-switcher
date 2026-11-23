import CryptoKit
import Foundation
import Testing
@testable import AGYCore

struct GitHubReleaseTests {
    @Test func selectsTheNumericallyNewerStableUniversalRelease() throws {
        let candidate = try GitHubRelease.update(from: releaseData(), currentVersion: version("0.9.12"))
        let update = try #require(candidate)
        #expect(update.tag == "v0.10.0")
        #expect(update.notesURL(language: .english).path == "/tyuan511/agy-switcher/releases/tag/v0.10.0")
        #expect(update.notesURL(language: .simplifiedChinese).path.hasSuffix("/docs/release/v0.10.0_zh-CN.md"))
    }

    @Test func skipsTheCurrentVersionDowngradesDraftsAndPrereleases() throws {
        let current = try version("0.10.0")
        #expect(try GitHubRelease.update(from: releaseData(), currentVersion: current) == nil)
        #expect(try GitHubRelease.update(from: releaseData(tag: "v0.9.12"), currentVersion: current) == nil)
        #expect(try GitHubRelease.update(from: releaseData(tag: "v1.0.0", draft: true), currentVersion: current) == nil)
        #expect(try GitHubRelease.update(from: releaseData(tag: "v1.0.0", prerelease: true), currentVersion: current) == nil)
        #expect(try GitHubRelease.update(from: releaseData(tag: "v1.0.0-rc.1"), currentVersion: current) == nil)
    }

    @Test(arguments: [GitHubRelease.Architecture.arm64, .amd64])
    func prefersTheMatchingInstallerOverUniversal(_ architecture: GitHubRelease.Architecture) throws {
        let data = try releaseData(additionalAssets: [
            ["id": 2, "name": "AGY-Switcher-v0.10.0-macOS-arm64.dmg", "state": "uploaded", "size": 3],
            ["id": 3, "name": "AGY-Switcher-v0.10.0-macOS-amd64.dmg", "state": "uploaded", "size": 5],
        ])
        let candidate = try GitHubRelease.update(from: data, currentVersion: version("0.9.0"), architecture: architecture)
        let update = try #require(candidate)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(count: architecture == .arm64 ? 3 : 5).write(to: file)
        try update.verifyDownload(at: file)
    }

    @Test func requiresTheUploadedDMGForTheSelectedTag() throws {
        let current = try version("0.9.0")
        #expect(throws: UpdateError.invalidRelease) {
            try GitHubRelease.update(from: releaseData(name: "AGY-Switcher-v0.9.0-macOS-universal.dmg"), currentVersion: current)
        }
        #expect(throws: UpdateError.invalidRelease) {
            try GitHubRelease.update(from: releaseData(state: "starter"), currentVersion: current)
        }
        let wrongArchitecture = try releaseData(name: "AGY-Switcher-v0.10.0-macOS-amd64.dmg")
        #expect(throws: UpdateError.invalidRelease) {
            try GitHubRelease.update(from: wrongArchitecture, currentVersion: current, architecture: .arm64)
        }
    }

    @Test func rejectsSizeAndDigestMismatches() throws {
        let bytes = Data("release".utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let candidate = try GitHubRelease.update(
            from: releaseData(size: bytes.count, digest: "sha256:\(hash)"), currentVersion: version("0.9.0")
        )
        let update = try #require(candidate)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try bytes.write(to: file)
        try update.verifyDownload(at: file)
        for malformed in ["tamper!", "short"] {
            try Data(malformed.utf8).write(to: file)
            #expect(throws: UpdateError.invalidDownload) { try update.verifyDownload(at: file) }
        }
    }

    @Test func restrictsRedirectsToGitHubHTTPSHosts() throws {
        func request(_ url: String) throws -> URLRequest {
            URLRequest(url: try #require(URL(string: url)))
        }
        let api = try request("https://api.github.com/repos/tyuan511/agy-switcher/releases/latest")
        let asset = try request("https://release-assets.githubusercontent.com/example.dmg")
        #expect(GitHubReleaseRedirects.validated(api) == api)
        #expect(GitHubReleaseRedirects.validated(asset) == asset)
        #expect(try GitHubReleaseRedirects.validated(request("http://api.github.com/no-https")) == nil)
        #expect(try GitHubReleaseRedirects.validated(request("https://api.github.com.example.org/untrusted")) == nil)
    }

    @Test func distinguishesMissingReleasesFromMissingRepositories() async throws {
        let current = try version("0.9.0")
        func latestUpdate(using repository: URLProtocol.Type) async throws -> GitHubRelease? {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [repository]
            let client = GitHubReleaseClient(session: URLSession(configuration: configuration))
            return try await client.latestUpdate(after: current)
        }

        #expect(try await latestUpdate(using: ReleaseRepositoryStub.self) == nil)
        await #expect(throws: UpdateError.http(404)) {
            try await latestUpdate(using: MissingReleaseRepository.self)
        }
    }

    private func version(_ value: String) throws -> ReleaseVersion {
        try #require(ReleaseVersion(value))
    }

    private func releaseData(
        tag: String = "v0.10.0", draft: Bool = false, prerelease: Bool = false,
        name: String? = nil, state: String = "uploaded", size: Int = 42, digest: String? = nil,
        additionalAssets: [[String: Any]] = []
    ) throws -> Data {
        var asset: [String: Any] = [
            "id": 1, "name": name ?? "AGY-Switcher-\(tag)-macOS-universal.dmg", "state": state, "size": size,
        ]
        asset["digest"] = digest
        return try JSONSerialization.data(withJSONObject: [
            "tag_name": tag, "draft": draft, "prerelease": prerelease, "assets": [asset] + additionalAssets,
        ])
    }
}

private class ReleaseRepositoryStub: URLProtocol, @unchecked Sendable {
    class var repositoryStatus: Int { 200 }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        guard request.value(forHTTPHeaderField: "Authorization") == nil else {
            client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
            return
        }
        let path = "/repos/\(GitHubRelease.repository)"
        let status = url.path == path ? type(of: self).repositoryStatus : 404
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class MissingReleaseRepository: ReleaseRepositoryStub, @unchecked Sendable {
    override class var repositoryStatus: Int { 404 }
}
