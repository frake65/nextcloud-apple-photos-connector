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

    public func initiate(server: String) async throws -> LoginFlowStartResponse {
        guard let base = normalizedServer(server) else { throw LoginFlowError.invalidServer }
        var request = URLRequest(url: base.appendingPathComponent("index.php/login/v2"))
        request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        do {
            let response = try await transport.send(request, file: nil)
            guard (200..<300).contains(response.status), let value = try? JSONDecoder().decode(LoginFlowStartResponse.self, from: response.data) else {
                throw LoginFlowError.http(response.status)
            }
            guard !value.poll.token.isEmpty, Self.isSecure(value.login), Self.isSecure(value.poll.endpoint) else { throw LoginFlowError.invalidReturnedURL }
            return value
        } catch let error as LoginFlowError { throw error } catch { throw LoginFlowError.network }
    }

    public func poll(_ start: LoginFlowStartResponse) async throws -> LoginFlowCredentials {
        guard Self.isSecure(start.login), Self.isSecure(start.poll.endpoint) else { throw LoginFlowError.invalidReturnedURL }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            var request = URLRequest(url: start.poll.endpoint); request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = "token=\(Self.formEncode(start.poll.token))".data(using: .utf8)
            do {
                let response = try await transport.send(request, file: nil)
                if response.status == 404 { try await Task.sleep(for: pollInterval); continue }
                guard (200..<300).contains(response.status) else { throw LoginFlowError.http(response.status) }
                guard let credentials = try? JSONDecoder().decode(LoginFlowCredentials.self, from: response.data), !credentials.loginName.isEmpty, !credentials.appPassword.isEmpty, Self.isSecure(credentials.server) else { throw LoginFlowError.invalidResponse }
                return credentials
            } catch is CancellationError { throw LoginFlowError.cancelled }
            catch UploadError.http(404) {
                // NetworkTransport throws for HTTP errors; 404 means pending in Login Flow v2.
                try await Task.sleep(for: pollInterval)
                continue
            }
            catch let error as LoginFlowError { throw error }
            catch { throw LoginFlowError.network }
        }
        throw LoginFlowError.timeout
    }

    private func normalizedServer(_ value: String) -> URL? {
        guard var components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)), components.scheme == "https", components.host != nil, components.user == nil, components.password == nil, components.query == nil, components.fragment == nil else { return nil }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")); return components.url
    }
    private static func isSecure(_ url: URL) -> Bool { url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil }
    private static func formEncode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))) ?? value }
}
