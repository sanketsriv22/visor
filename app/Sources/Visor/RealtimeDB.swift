import Foundation

/// The small part of Firebase's Realtime Database that Visor actually used.
///
/// The SDK cost 25 MB of the app — more than five times everything Visor's own
/// code compiles to — for a document store and a change stream, both of which
/// the service exposes over plain HTTPS. The REST endpoint even does live
/// updates: ask for `text/event-stream` and it pushes every change as a
/// server-sent event, which is the one capability that seemed to justify
/// linking a database engine into the binary.
///
/// What genuinely doesn't survive the move is `onDisconnect` — the SDK's
/// promise to clean up your presence node if you crash, which depends on the
/// server watching a socket it owns. Presence is a heartbeat here instead:
/// clients say they're alive periodically and are counted while recent. A
/// crashed client lingers for one timeout rather than vanishing instantly,
/// which is a fair price for a fortieth of the size.
struct RealtimeDB {
    let base: URL

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        // The event stream is a response that never ends; the default 60s
        // resource timeout would sever it on the minute.
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = .infinity
        return URLSession(configuration: config)
    }()

    private func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(
            url: base.appendingPathComponent(path + ".json"),
            resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    /// A server-side timestamp, in the form the REST API accepts.
    static let serverTimestamp: [String: String] = [".sv": "timestamp"]

    // MARK: - Reads and writes

    func get(_ path: String) async -> Any? {
        guard let (data, _) = try? await Self.session.data(from: url(path)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    @discardableResult
    func put(_ path: String, _ value: Any) async -> Bool {
        await write(path, value, method: "PUT") != nil
    }

    /// Appends under a server-generated key, the REST equivalent of
    /// `childByAutoId`. Returns that key.
    @discardableResult
    func post(_ path: String, _ value: Any) async -> String? {
        guard let data = await write(path, value, method: "POST"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["name"] as? String
    }

    func delete(_ path: String) async {
        var request = URLRequest(url: url(path))
        request.httpMethod = "DELETE"
        _ = try? await Self.session.data(for: request)
    }

    private func write(_ path: String, _ value: Any, method: String) async -> Data? {
        var request = URLRequest(url: url(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: value,
                                                       options: [.fragmentsAllowed])
        guard let (data, response) = try? await Self.session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        return data
    }

    // MARK: - Live updates

    /// One change at `path`, relative to the node being watched.
    struct Event {
        /// "/" for the whole node, "/key" for one child.
        let path: String
        /// nil when the node or child was removed.
        let value: Any?
    }

    /// Watch a node. The first event carries everything currently there; each one
    /// after is a change.
    ///
    /// Ends when the task is cancelled — the caller cancels to unsubscribe, which
    /// closes the connection.
    func stream(_ path: String, query: [URLQueryItem] = []) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task {
                var request = URLRequest(url: url(path, query: query))
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                guard let (bytes, _) = try? await Self.session.bytes(for: request) else {
                    continuation.finish()
                    return
                }
                // Server-sent events arrive as an "event:" line and a "data:"
                // line; anything else (keep-alives, blank separators) is noise.
                var kind = ""
                do {
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        if line.hasPrefix("event:") {
                            kind = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            // Only put and patch carry state. `keep-alive`,
                            // `auth_revoked` and `cancel` don't.
                            guard kind == "put" || kind == "patch" else { continue }
                            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            guard let data = payload.data(using: .utf8),
                                  let object = try? JSONSerialization.jsonObject(
                                    with: data, options: [.fragmentsAllowed]) as? [String: Any],
                                  let where_ = object["path"] as? String
                            else { continue }
                            let value = object["data"]
                            continuation.yield(Event(
                                path: where_,
                                value: value is NSNull ? nil : value))
                        }
                    }
                } catch {
                    // A dropped stream is a finished stream; the caller decides
                    // whether to reopen it.
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
