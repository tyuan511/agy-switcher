import Foundation
import Network

enum LoopbackOAuth {
    typealias Browser = @MainActor @Sendable (URL) -> Bool

    static func authorize(
        with oauth: GoogleOAuth, email: String?, language: AppLanguage, openBrowser: @escaping Browser
    ) async throws -> AntigravityCredential {
        let attempt = try OAuthAttempt()
        let queue = DispatchQueue(label: "agy-switcher.oauth")
        let tcp = NWParameters.tcp
        tcp.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: tcp)

        let events = AsyncThrowingStream<Event, Error> { continuation in
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    if let port = listener?.port,
                       let redirect = URL(string: "http://127.0.0.1:\(port.rawValue)\(OAuthAttempt.callbackPath)") {
                        continuation.yield(.ready(redirect))
                    } else {
                        continuation.finish(throwing: AGYError.invalidResponse)
                    }
                case .failed(let error):
                    continuation.finish(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { connection in
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 8) { connection.cancel() }
                receive(connection, buffer: Data(), attempt: attempt, language: language, continuation: continuation)
            }
            continuation.onTermination = { @Sendable _ in listener.cancel() }
            listener.start(queue: queue)
        }
        defer { listener.cancel() }

        let callback = try await withThrowingTaskGroup(of: AuthorizationCode.self) { group in
            group.addTask {
                var redirect: URL?
                for try await event in events {
                    try Task.checkCancellation()
                    switch event {
                    case .ready(let url):
                        redirect = url
                        guard await openBrowser(oauth.authorizationURL(redirect: url, attempt: attempt, email: email)) else {
                            throw AGYError.browserUnavailable
                        }
                    case .code(let code):
                        guard let redirect else { throw AGYError.invalidResponse }
                        return AuthorizationCode(code: code, redirect: redirect)
                    }
                }
                try Task.checkCancellation()
                throw AGYError.authorizationDenied
            }
            group.addTask {
                try await Task.sleep(for: .seconds(180))
                throw AGYError.authorizationTimedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw AGYError.authorizationDenied }
            return result
        }

        return try await oauth.exchange(code: callback.code, redirect: callback.redirect, attempt: attempt)
    }

    private struct AuthorizationCode: Sendable {
        let code: String
        let redirect: URL
    }

    private enum Event: Sendable {
        case ready(URL)
        case code(String)
    }

    private static func receive(
        _ connection: NWConnection, buffer: Data, attempt: OAuthAttempt, language: AppLanguage,
        continuation: AsyncThrowingStream<Event, Error>.Continuation
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { chunk, _, complete, error in
            var received = buffer
            if let chunk { received.append(chunk) }
            if received.count <= 16_384, let newline = received.firstIndex(of: 10) {
                let line = String(decoding: received[..<newline], as: UTF8.self).split(whereSeparator: \.isWhitespace)
                let callback = line.count == 3 && line[0] == "GET"
                    ? attempt.callback(requestTarget: String(line[1])) : .invalid
                respond(connection, callback: callback, language: language) {
                    switch callback {
                    case .code(let code):
                        continuation.yield(.code(code))
                        continuation.finish()
                    case .denied: continuation.finish(throwing: AGYError.authorizationDenied)
                    case .invalid: break
                    }
                }
            } else if received.count <= 16_384 && !complete && error == nil {
                receive(connection, buffer: received, attempt: attempt, language: language, continuation: continuation)
            } else {
                connection.cancel()
            }
        }
    }

    private static func respond(
        _ connection: NWConnection, callback: OAuthAttempt.Callback, language: AppLanguage,
        finished: @escaping @Sendable () -> Void
    ) {
        let response = OAuthCallbackPage.response(for: callback, language: language)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
            finished()
        })
    }
}
