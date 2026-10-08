import Foundation

public struct LoginFlowStartResponse: Decodable, Sendable {
    public struct Poll: Decodable, Sendable {
        public let token: String; public let endpoint: URL
        public init(token: String, endpoint: URL) { self.token = token; self.endpoint = endpoint }
    }
    public let poll: Poll
    public let login: URL
    public init(poll: Poll, login: URL) { self.poll = poll; self.login = login }
}

public struct LoginFlowCredentials: Decodable, Sendable {
    public let server: URL
    public let loginName: String
    public let appPassword: String
    public init(server: URL, loginName: String, appPassword: String) { self.server = server; self.loginName = loginName; self.appPassword = appPassword }
}

public enum LoginFlowError: Error, Sendable, Equatable {
    case invalidServer, invalidResponse, invalidReturnedURL, timeout, cancelled, http(Int), network
}

/// Nextcloud Login Flow v2 client. Tokens and returned passwords exist only in memory.
public struct NextcloudLoginFlowService: Sendable {
    public let transport: any DAVTransport
    public let pollInterval: Duration
    public let timeout: Duration

    public init(transport: any DAVTransport = NetworkTransport(), pollInterval: Duration = .seconds(1), timeout: Duration = .seconds(1200)) {
        self.transport = transport; self.pollInterval = pollInterval; self.timeout = timeout
    }

    private func diagnostic(_ event: String) {
        print("APC LOGIN \(event)")
    }

    private func seconds(_ interval: TimeInterval) -> String { String(format: "%.3f", interval) }

    private func diagnosticError(_ error: Error) -> String {
        if let error = error as? URLError {
            let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            let underlyingDescription = underlying.map { "\($0.domain):\($0.code)" } ?? "none"
            return "type=URLError code=\(error.code.rawValue) symbol=\(error.code) underlying=\(underlyingDescription)"
        }
        if let error = error as? UploadError {
            if case let .http(status) = error { return "type=UploadError.http status=\(status)" }
            return "type=UploadError case=\(error)"
        }
        if let error = error as? DecodingError { return "type=DecodingError case=\(error)" }
        let nsError = error as NSError
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        let underlyingDescription = underlying.map { "\($0.domain):\($0.code)" } ?? "none"
        return "type=\(String(reflecting: type(of: error))) underlying=\(underlyingDescription)"
    }

    public func initiate(server: String) async throws -> LoginFlowStartResponse {
        diagnostic("loginFlow.request.start host=\(URL(string: server)?.host ?? "invalid")")
        guard let base = normalizedServer(server) else { diagnostic("login.failure phase=loginFlow.request error=invalidServer"); throw LoginFlowError.invalidServer }
        var request = URLRequest(url: base.appendingPathComponent("index.php/login/v2"))
        request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        do {
            let response = try await transport.send(request, file: nil)
            diagnostic("loginFlow.request.response status=\(response.status)")
            guard (200..<300).contains(response.status), let value = try? JSONDecoder().decode(LoginFlowStartResponse.self, from: response.data) else {
                throw LoginFlowError.http(response.status)
            }
            guard !value.poll.token.isEmpty, Self.isSecure(value.login), Self.isSecure(value.poll.endpoint) else { throw LoginFlowError.invalidReturnedURL }
            return value
        } catch let error as LoginFlowError { diagnostic("login.failure phase=loginFlow.request error=\(error)"); throw error } catch { diagnostic("login.failure phase=loginFlow.request error=network"); throw LoginFlowError.network }
    }

    public func poll(_ start: LoginFlowStartResponse) async throws -> LoginFlowCredentials {
        guard Self.isSecure(start.login), Self.isSecure(start.poll.endpoint) else { throw LoginFlowError.invalidReturnedURL }
        diagnostic("poll.start host=\(start.poll.endpoint.host ?? "unknown")")
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let pollingStarted = Date()
        var consecutiveConnectionLosses = 0
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            var request = URLRequest(url: start.poll.endpoint); request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = "token=\(Self.formEncode(start.poll.token))".data(using: .utf8)
            let requestStarted = Date()
            let pollHost = start.poll.endpoint.host ?? "unknown"
            diagnostic("poll.request.start method=POST host=\(pollHost) path=\(start.poll.endpoint.path) contentType=application/x-www-form-urlencoded tokenPresent=true requestTimeout=\(request.timeoutInterval) sessionRequestTimeout=20 sessionResourceTimeout=30 deadline=\(timeout)")
            do {
                let response = try await transport.send(request, file: nil)
                let duration = Date().timeIntervalSince(requestStarted)
                if response.status == 404 { diagnostic("poll.pending status=404 requestDuration=\(seconds(duration)) totalDuration=\(seconds(Date().timeIntervalSince(pollingStarted)))"); try await Task.sleep(for: pollInterval); continue }
                guard (200..<300).contains(response.status) else { throw LoginFlowError.http(response.status) }
                consecutiveConnectionLosses = 0
                let credentials: LoginFlowCredentials
                do { credentials = try JSONDecoder().decode(LoginFlowCredentials.self, from: response.data) }
                catch { diagnostic("poll.decode.failure \(diagnosticError(error)) requestDuration=\(seconds(duration))"); throw LoginFlowError.invalidResponse }
                guard !credentials.loginName.isEmpty, !credentials.appPassword.isEmpty, Self.isSecure(credentials.server) else { throw LoginFlowError.invalidResponse }
                diagnostic("poll.success status=\(response.status) requestDuration=\(seconds(duration)) totalDuration=\(seconds(Date().timeIntervalSince(pollingStarted)))")
                return credentials
            } catch is CancellationError { diagnostic("login.failure phase=poll error=CancellationError requestDuration=\(seconds(Date().timeIntervalSince(requestStarted)))"); throw LoginFlowError.cancelled }
            catch UploadError.http(404) {
                // NetworkTransport throws for HTTP errors; 404 means pending in Login Flow v2.
                diagnostic("poll.pending status=404 requestDuration=\(seconds(Date().timeIntervalSince(requestStarted))) totalDuration=\(seconds(Date().timeIntervalSince(pollingStarted)))")
                try await Task.sleep(for: pollInterval)
                continue
            }
            catch let error as LoginFlowError { diagnostic("login.failure phase=poll error=\(error) requestDuration=\(seconds(Date().timeIntervalSince(requestStarted))) totalDuration=\(seconds(Date().timeIntervalSince(pollingStarted)))"); throw error }
            catch UploadError.http(let status) { diagnostic("login.failure phase=poll \(diagnosticError(UploadError.http(status))) requestDuration=\(seconds(Date().timeIntervalSince(requestStarted))) totalDuration=\(seconds(Date().timeIntervalSince(pollingStarted)))"); throw LoginFlowError.network }
            catch let error as URLError where error.code == .networkConnectionLost {
                consecutiveConnectionLosses += 1
                let delay = min(0.5 * pow(2.0, Double(consecutiveConnectionLosses - 1)), 5.0)
                diagnostic("poll.retry reason=networkConnectionLost consecutive=\(consecutiveConnectionLosses) delay=\(seconds(delay)) requestDuration=\(seconds(Date().timeIntervalSince(requestStarted))) totalDuration=\(seconds(Date().timeIntervalSince(pollingStarted)))")
                do { try await Task.sleep(for: .milliseconds(Int(delay * 1000))) }
                catch is CancellationError { throw LoginFlowError.cancelled }
                continue
            }
            catch { diagnostic("login.failure phase=poll \(diagnosticError(error)) requestDuration=\(seconds(Date().timeIntervalSince(requestStarted))) totalDuration=\(seconds(Date().timeIntervalSince(pollingStarted)))"); throw LoginFlowError.network }
        }
        diagnostic("login.failure phase=poll error=timeout")
        throw LoginFlowError.timeout
    }

    private func normalizedServer(_ value: String) -> URL? {
        guard var components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)), components.scheme == "https", components.host != nil, components.user == nil, components.password == nil, components.query == nil, components.fragment == nil else { return nil }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")); return components.url
    }
    private static func isSecure(_ url: URL) -> Bool { url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil }
    private static func formEncode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))) ?? value }
}
