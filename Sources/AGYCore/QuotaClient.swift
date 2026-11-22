import Foundation

struct QuotaClient: Sendable {
    private enum Action: String {
        case loadCodeAssist
        case retrieveUserQuotaSummary
        case fetchAvailableModels
    }

    let send: HTTPTransport
    let version: String

    init(version: String, send: @escaping HTTPTransport = GoogleHTTP.send) {
        self.version = version
        self.send = send
    }

    func fetch(for credential: AntigravityCredential) async throws -> QuotaSnapshot {
        let accessToken = credential.token.accessToken
        let load = try await attempt {
            let data = try await post(.loadCodeAssist, accessToken: accessToken, body: [
                "mode": "FULL_ELIGIBILITY_CHECK",
                "metadata": [
                    "ideName": "antigravity",
                    "ideType": "ANTIGRAVITY",
                    "ideVersion": version,
                    "pluginVersion": version,
                    "platform": "DARWIN_" + Self.architecture.uppercased(),
                    "updateChannel": "stable",
                    "pluginType": "GEMINI",
                ],
            ])
            return try JSONDecoder().decode(Entitlement.self, from: data)
        }
        let entitlement = try? load.get()
        let parameters = (entitlement?.project).map { ["project": $0] } ?? [:]

        async let summary = attempt {
            let data = try await post(.retrieveUserQuotaSummary, accessToken: accessToken, body: parameters)
            return try JSONDecoder().decode(Summary.self, from: data).entries
        }
        async let models = attempt {
            let data = try await post(.fetchAvailableModels, accessToken: accessToken, body: parameters)
            return try JSONDecoder().decode(ModelList.self, from: data).entries
        }
        let (groupResult, modelResult) = try await (summary, models)
        let groups = (try? groupResult.get()) ?? []
        let modelEntries = (try? modelResult.get()) ?? []
        let entries = groups.isEmpty ? modelEntries : groups
        if entries.isEmpty {
            _ = try groupResult.get()
            _ = try modelResult.get()
            throw AGYError.noQuota
        }
        return QuotaSnapshot(
            entries: entries,
            updatedAt: .now,
            tier: entitlement?.tier,
            partial: groups.isEmpty
        )
    }

    private func attempt<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> Result<T, Error> {
        do {
            return .success(try await body())
        } catch AGYError.authenticationRequired {
            throw AGYError.authenticationRequired
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failure(error)
        }
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "amd64"
        #endif
    }

    private func post(_ action: Action, accessToken: String, body: [String: Any]) async throws -> Data {
        let endpoint = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:" + action.rawValue)!
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The summary response uses the client identity to select which quota buckets it reports.
        let client = action == .retrieveUserQuotaSummary ? "antigravity/hub" : "antigravity"
        request.setValue("\(client)/\(version) darwin/\(Self.architecture)", forHTTPHeaderField: "User-Agent")
        let (data, status) = try await send(request)
        if status == 401 { throw AGYError.authenticationRequired }
        guard (200..<300).contains(status) else { throw AGYError.serviceRejected(status) }
        return data
    }

    private struct Entitlement: Decodable {
        struct Tier: Decodable { let id: String? }
        struct Project: Decodable { let id: String? }

        let project: String?
        let tier: String?

        enum CodingKeys: String, CodingKey {
            case cloudaicompanionProject, currentTier, paidTier
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            project = (try? values.decode(String.self, forKey: .cloudaicompanionProject))
                ?? (try? values.decode(Project.self, forKey: .cloudaicompanionProject).id)
            let paid = try values.decodeIfPresent(Tier.self, forKey: .paidTier)
            let current = try values.decodeIfPresent(Tier.self, forKey: .currentTier)
            switch paid?.id ?? current?.id {
            case "free-tier": tier = "Free"
            case "g1-pro-tier": tier = "Pro"
            case "g1-ultra-tier": tier = "Ultra"
            default: tier = nil
            }
        }
    }

    private struct Summary: Decodable {
        struct Group: Decodable {
            let displayName: String?
            let buckets: [Bucket]?
        }

        struct Bucket: Decodable {
            struct Remaining: Decodable {
                let remainingFraction: Double?
                let resetTime: String?
            }

            let bucketId: String?
            let displayName: String?
            let remainingFraction: Double?
            let resetTime: String?
            let remaining: Remaining?
        }

        let groups: [Group]

        var entries: [QuotaEntry] {
            var entries: [String: QuotaEntry] = [:]
            for group in groups {
                for bucket in group.buckets ?? [] {
                    guard let id = bucket.bucketId, !id.isEmpty,
                          let fraction = bucket.remaining?.remainingFraction ?? bucket.remainingFraction,
                          (0...1).contains(fraction) else { continue }
                    let key = id.lowercased()
                    let window = key.contains("weekly") ? "每周" : (key.hasSuffix("5h") ? "5 小时" : nil)
                    let name = bucket.displayName ?? group.displayName ?? Self.groupName(key)
                    let resetsAt = (bucket.remaining?.resetTime ?? bucket.resetTime).flatMap(parseTimestamp)
                    entries[id] = QuotaEntry(id: id, name: name, window: window, fraction: fraction, resetsAt: resetsAt,
                                             groupName: group.displayName)
                }
            }
            return entries.values.sorted(by: quotaOrder)
        }

        private static func groupName(_ id: String) -> String {
            if id.hasPrefix("3p") || id.hasPrefix("claude") { return "Claude / GPT" }
            if id.hasPrefix("gemini") { return "Gemini" }
            return id
        }
    }

    private struct ModelList: Decodable {
        struct Model: Decodable {
            struct Quota: Decodable {
                let remainingFraction: Double?
                let resetTime: String?
            }
            let displayName: String?
            let quotaInfo: Quota?
        }
        let models: [String: Model]

        var entries: [QuotaEntry] {
            models.compactMap { id, model in
                guard let quota = model.quotaInfo, let fraction = quota.remainingFraction,
                      (0...1).contains(fraction) else { return nil }
                return QuotaEntry(id: id, name: model.displayName ?? id, window: nil,
                                  fraction: fraction, resetsAt: quota.resetTime.flatMap(parseTimestamp))
            }.sorted(by: quotaOrder)
        }
    }
}

private func quotaOrder(_ first: QuotaEntry, _ second: QuotaEntry) -> Bool {
    if first.name == second.name { return first.id < second.id }
    return first.name.localizedStandardCompare(second.name) == .orderedAscending
}
