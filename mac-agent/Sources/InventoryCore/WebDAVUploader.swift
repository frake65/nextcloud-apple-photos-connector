import Foundation

public struct DAVResponse: Sendable {
    public let status: Int
    public let data: Data
    public let headers: [String: String]
    public init(status: Int, data: Data = Data(), headers: [String: String] = [:]) { self.status = status; self.data = data; self.headers = headers }
}

public protocol DAVTransport: Sendable {
    func send(_ request: URLRequest, file: URL?) async throws -> DAVResponse
}

/// Redirects are rejected, including same-origin redirects, to preserve conditional PUT semantics.
public final class NetworkTransport: NSObject, DAVTransport, URLSessionTaskDelegate, Sendable {
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    public func send(_ request: URLRequest, file: URL?) async throws -> DAVResponse {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let result: (Data, URLResponse)
        if let file { result = try await session.upload(for: request, fromFile: file) }
        else { result = try await session.data(for: request) }
        guard let response = result.1 as? HTTPURLResponse else { throw UploadError.invalidResponse }
        var headers: [String: String] = [:]; for (key, value) in response.allHeaderFields { headers[String(describing: key)] = String(describing: value) }
        return DAVResponse(status: response.statusCode, data: result.0, headers: headers)
    }
}

public enum UploadError: LocalizedError {
    case invalidConfiguration, invalidFilename, invalidResponse, http(Int), diagnostic(String), collisions
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Gültige HTTPS-Serveradresse und Zugangsdaten erforderlich."
        case .invalidFilename: "Originaldateiname fehlt oder ist für den Upload nicht zulässig."
        case .invalidResponse: "Unerwartete Serverantwort."
        case .http(let code): "Serveranfrage fehlgeschlagen (HTTP \(code))."
        case .diagnostic(let detail): detail
        case .collisions: "Kein freier Dateiname gefunden."
        }
    }
}

public struct ConnectorConnection: Sendable {
    public let base: URL
    public let user: String
    private let authorization: String
    public init(server: String, user: String, password: String) throws {
        guard let url = URL(string: server), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !user.isEmpty, !user.contains(":"), !user.contains("/"), !password.isEmpty else { throw UploadError.invalidConfiguration }
        base = url; self.user = user
        authorization = "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
    }
    public func request(path: [String], method: String) -> URLRequest {
        let url = path.reduce(base) { $0.appendingPathComponent($1) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 300
        return request
    }
}

public struct WebDAVUploader: Sendable {
    public static let directory = ["Photos", "Apple Photos Connector"]
    let connection: ConnectorConnection
    let transport: any DAVTransport
    let debug: (@Sendable (String) -> Void)?
    public init(connection: ConnectorConnection, transport: any DAVTransport, debug: (@Sendable (String) -> Void)? = nil) { self.connection = connection; self.transport = transport; self.debug = debug }

    public static func filename(_ original: String, assetId: String, attempt: Int) throws -> String {
        guard !original.isEmpty, ![".", ".."].contains(original),
              !original.contains("/"), !original.contains("\\"), !original.unicodeScalars.contains(where: { $0.value < 32 }),
              !assetId.isEmpty, assetId.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw UploadError.invalidFilename }
        if attempt == 0 { return original }
        let dot = original.lastIndex(of: ".")
        let split = dot != original.startIndex ? dot : nil
        let stem = split.map { String(original[..<$0]) } ?? original
        let ext = split.map { String(original[$0...]) } ?? ""
        return stem + "--apc-" + assetId + (attempt > 1 ? "-\(attempt - 1)" : "") + ext
    }

    public func upload(file: URL, filename: String, assetId: String, captureDate: Date, targets: any UploadTargetProvider, targetRoot: String = "Photos/Apple Photos Connector") async throws -> String {
        let identity = try ContentIdentity.read(file)
        let root = ["remote.php", "dav", "files", connection.user]
        let rootComponents = try Self.safeComponents(targetRoot)
        for count in 1...rootComponents.count {
            let request = connection.request(path: root + rootComponents.prefix(count), method: "MKCOL")
            debug?("Request MKCOL · path=\(request.url?.path ?? "")")
            let response = try await transport.send(request, file: nil)
            debug?("Response MKCOL · status=\(response.status) · responseBytes=\(response.data.count)")
            guard [201, 405].contains(response.status) else { throw UploadError.http(response.status) }
        }
        for _ in 0..<100 {
            try Task.checkCancellation()
            let target = try await targets.prepare(identity: identity)
            let assetIdMatch = target.assetId == assetId
            let bytesMatch = target.bytes == identity.bytes
            let shaMatch = target.sha256 == identity.sha256
            let targetComponents = try Self.safeComponents(target.path)
            let pathPrefixMatch = Self.isValidTargetPath(target.path, under: targetRoot)
            let stateMatch = ["missing", "present"].contains(target.state)
            debug?("upload.prepare.validate.assetId=\(assetIdMatch)")
            debug?("upload.prepare.validate.bytes=\(bytesMatch)")
            debug?("upload.prepare.validate.sha256=\(shaMatch)")
            debug?("upload.prepare.validate.pathPrefix=\(pathPrefixMatch)")
            debug?("upload.prepare.validate.state=\(stateMatch)")
            let pathDepth = target.path.split(separator: "/").count
            debug?("upload.prepare.target.state=\(stateMatch ? target.state : "other")")
            debug?("upload.prepare.target.pathDepth=\(pathDepth)")
            debug?("upload.prepare.target.bytesMatch=\(bytesMatch)")
            guard assetIdMatch, bytesMatch, shaMatch, pathPrefixMatch, stateMatch else { throw UploadError.invalidResponse }
            // Do not permit a server response to redirect uploads outside the fixed target directory.
            let names = try (0..<100).map { try Self.filename(filename, assetId: assetId, attempt: $0) }
            let filenameMatch = names.contains(target.path.split(separator: "/").last.map(String.init) ?? "")
            debug?("upload.prepare.validate.filename=\(filenameMatch)")
            guard filenameMatch else { throw UploadError.invalidResponse }
            if target.state == "present" { return target.path }
            if targetComponents.count > rootComponents.count + 1 {
                for count in (rootComponents.count + 1)..<targetComponents.count {
                    let folder = root + Array(targetComponents.prefix(count))
                    let request = connection.request(path: folder, method: "MKCOL")
                    debug?("Request MKCOL · path=\(request.url?.path ?? "")")
                    let response = try await transport.send(request, file: nil)
                    debug?("Response MKCOL · status=\(response.status) · responseBytes=\(response.data.count)")
                    guard [201, 405].contains(response.status) else { throw UploadError.http(response.status) }
                }
            }
            var request = connection.request(path: root + targetComponents, method: "PUT")
            request.setValue("*", forHTTPHeaderField: "If-None-Match")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue(String(Int(captureDate.timeIntervalSince1970)), forHTTPHeaderField: "X-OC-MTime")
            debug?("Request PUT · path=\(request.url?.path ?? "") · fileBytes=\(identity.bytes)")
            debug?("upload.put.start")
            let response = try await transport.send(request, file: file)
            debug?("upload.put.status=\(response.status)")
            debug?("Response PUT · status=\(response.status) · responseBytes=\(response.data.count)")
            if response.status == 201 { return target.path }
            // A concurrent successful PUT is rechecked by prepare. No speculative next filename.
            if response.status != 412 { throw UploadError.http(response.status) }
        }
        throw UploadError.collisions
    }

    private static func safeComponents(_ path: String) throws -> [String] {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasSuffix("/"), !path.contains("\\") else { throw UploadError.invalidResponse }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.unicodeScalars.contains(where: { $0.value < 32 }) }) else { throw UploadError.invalidResponse }
        return parts
    }

    static func isValidTargetPath(_ path: String, under root: String) -> Bool {
        guard let rootParts = try? safeComponents(root), let pathParts = try? safeComponents(path) else { return false }
        return pathParts.count > rootParts.count && Array(pathParts.prefix(rootParts.count)) == rootParts
    }
}
