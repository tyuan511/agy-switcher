import CryptoKit
import Foundation

struct ReleaseVersion: Comparable, Sendable, CustomStringConvertible {
    private let components: [Int]

    init?(_ version: String) {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == 3, zip(parts, numbers).allSatisfy({ part, number in
            number >= 0 && part == String(number)
        }) else { return nil }
        components = numbers
    }

    var description: String { components.map(String.init).joined(separator: ".") }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

enum UpdateError: Error, Equatable {
    case http(Int)
    case invalidRelease
    case invalidDownload
    case invalidSignature
    case missingNotarization
    case installationLocation
    case installationFailed

    var message: String.LocalizationValue {
        switch self {
        case .http(let status): "GitHub 请求失败（HTTP \(String(status))）。"
        case .invalidRelease: "GitHub Release 缺少有效的 macOS 更新包。"
        case .invalidDownload: "下载的更新包不完整或校验失败。"
        case .invalidSignature: "更新包的版本、应用标识或签名校验失败。"
        case .missingNotarization: "更新包未通过 Apple 公证校验。"
        case .installationLocation: "请将 AGY Switcher 移到可写的应用程序目录，再尝试更新。"
        case .installationFailed: "无法安装更新，请重试或从 GitHub Release 手动安装。"
        }
    }
}

struct GitHubRelease: Sendable {
    static let repository = "tyuan511/agy-switcher"

    enum Architecture: String, Sendable {
        case arm64, amd64

        static var current: Self {
            #if arch(arm64)
            .arm64
            #else
            .amd64
            #endif
        }
    }

    let version: ReleaseVersion
    let tag: String
    fileprivate let asset: Asset

    fileprivate struct Asset: Decodable, Sendable {
        let id: Int64
        let name: String
        let size: Int64
        let state: String
        let digest: String?
    }

    private struct Response: Decodable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    static func update(from data: Data, currentVersion: ReleaseVersion,
                       architecture: Architecture = .current) throws -> Self? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let release = try? decoder.decode(Response.self, from: data) else {
            throw UpdateError.invalidRelease
        }
        let tag = release.tagName
        guard !release.draft, !release.prerelease, tag.hasPrefix("v"),
              let version = ReleaseVersion(String(tag.dropFirst())), version > currentVersion else { return nil }
        let prefix = "AGY-Switcher-\(tag)-macOS-"
        let uploaded = release.assets.filter { $0.state == "uploaded" && $0.id > 0 && $0.size > 0 }
        let matching = uploaded.first { $0.name == "\(prefix)\(architecture.rawValue).dmg" }
        let universal = uploaded.first { $0.name == "\(prefix)universal.dmg" }
        guard let asset = matching ?? universal else { throw UpdateError.invalidRelease }
        return Self(version: version, tag: tag, asset: asset)
    }

    func notesURL(language: AppLanguage) -> URL {
        let path = language == .simplifiedChinese
            ? "blob/\(tag)/docs/release/\(tag)_zh-CN.md"
            : "releases/tag/\(tag)"
        return URL(string: "https://github.com/\(Self.repository)/\(path)")!
    }

    func verifyDownload(at url: URL) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size, Int64(size) == asset.size else { throw UpdateError.invalidDownload }
        if let digest = asset.digest {
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            var hash = SHA256()
            while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
                hash.update(data: chunk)
            }
            let hex = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest.lowercased() == "sha256:\(hex)" else { throw UpdateError.invalidDownload }
        }
    }
}

struct GitHubReleaseClient: Sendable {
    private let session: URLSession

    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = session ?? URLSession(configuration: configuration)
    }

    func latestUpdate(after version: ReleaseVersion) async throws -> GitHubRelease? {
        let (data, response) = try await session.data(
            for: request(path: "/releases/latest"), delegate: GitHubReleaseRedirects()
        )
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 {
            let (_, repository) = try await session.data(
                for: request(path: ""), delegate: GitHubReleaseRedirects()
            )
            try validate(repository)
            return nil
        }
        try validate(response)
        return try GitHubRelease.update(from: data, currentVersion: version)
    }

    func download(_ update: GitHubRelease) async throws -> URL {
        let request = request(path: "/releases/assets/\(update.asset.id)", accept: "application/octet-stream")
        let (file, response) = try await session.download(for: request, delegate: GitHubReleaseRedirects())
        do {
            try validate(response)
            try update.verifyDownload(at: file)
            return file
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    private func request(path: String, accept: String = "application/vnd.github+json") -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(GitHubRelease.repository)\(path)")!)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        return request
    }

    private func validate(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.http(status) }
    }
}

final class GitHubReleaseRedirects: NSObject, URLSessionTaskDelegate {
    static func validated(_ request: URLRequest) -> URLRequest? {
        guard let url = request.url, url.scheme == "https", let host = url.host,
              url.port == nil || url.port == 443 else { return nil }
        guard host == "api.github.com" || host == "github.com" || host.hasSuffix(".githubusercontent.com") else {
            return nil
        }
        return request
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(Self.validated(request))
    }
}
