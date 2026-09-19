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
public final class NetworkTransport: NSObject, DAVTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private static let requestTimeout: TimeInterval = 20
    private var apiSession: URLSession!
    private var transferSession: URLSession!

    public override init() {
        let apiConfiguration = URLSessionConfiguration.ephemeral
        apiConfiguration.httpCookieStorage = nil
        apiConfiguration.timeoutIntervalForRequest = Self.requestTimeout
        apiConfiguration.timeoutIntervalForResource = 30
        let transferConfiguration = URLSessionConfiguration.ephemeral
        transferConfiguration.httpCookieStorage = nil
        transferConfiguration.timeoutIntervalForRequest = Self.requestTimeout
        transferConfiguration.timeoutIntervalForResource = 1800
        super.init()
        apiSession = URLSession(configuration: apiConfiguration, delegate: self, delegateQueue: nil)
        transferSession = URLSession(configuration: transferConfiguration, delegate: self, delegateQueue: nil)
    }

    deinit {
        apiSession?.invalidateAndCancel()
        transferSession?.invalidateAndCancel()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    public func send(_ request: URLRequest, file: URL?) async throws -> DAVResponse {
        let session: URLSession = (file == nil ? apiSession : transferSession)!
        var request = request
        request.timeoutInterval = file == nil ? Self.requestTimeout : 1800
        let result: (Data, URLResponse)
        if let file { result = try await session.upload(for: request, fromFile: file) }
        else { result = try await session.data(for: request) }
        guard let response = result.1 as? HTTPURLResponse else { throw UploadError.invalidResponse }
        var headers: [String: String] = [:]; for (key, value) in response.allHeaderFields { headers[String(describing: key)] = String(describing: value) }
        // WebDAV commonly answers MKCOL for an already existing directory
        // with 405. The caller explicitly treats that as successful/idempotent.
        // Preserve all other HTTP errors for normal error handling.
        let expectedExistingDirectory = request.httpMethod == "MKCOL" && response.statusCode == 405
        guard response.statusCode < 400 || expectedExistingDirectory else { throw UploadError.http(response.statusCode) }
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

public actor WebDAVFolderCoordinator {
    private var known: Set<String> = []
    private var inFlight: [String: Task<Void, Error>] = [:]
    public init() {}
    public func isEnsured(path: String) -> Bool { known.contains(path) }
    public func ensure(path: String, operation: @escaping @Sendable () async throws -> Void) async throws {
        if known.contains(path) { return }
        if let existing = inFlight[path] {
            try await withTaskCancellationHandler {
                try await existing.value
            } onCancel: {
                existing.cancel()
            }
            return
        }
        let task = Task { try await operation() }
        inFlight[path] = task
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            known.insert(path)
            inFlight.removeValue(forKey: path)
        } catch {
            inFlight.removeValue(forKey: path)
            throw error
        }
    }
}

public struct WebDAVUploader: Sendable {
    public static let directory = ["Photos", "Apple Photos Connector"]
    let connection: ConnectorConnection
    let transport: any DAVTransport
    let debug: (@Sendable (String) -> Void)?
    private let runFolderCoordinator: WebDAVFolderCoordinator
    public init(connection: ConnectorConnection, transport: any DAVTransport, debug: (@Sendable (String) -> Void)? = nil, folderCoordinator: WebDAVFolderCoordinator = WebDAVFolderCoordinator()) { self.connection = connection; self.transport = transport; self.debug = debug; self.runFolderCoordinator = folderCoordinator }

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

    public func upload(file: URL, filename: String, assetId: String, captureDate: Date, targets: any UploadTargetProvider, targetRoot: String = "Photos/Apple Photos Connector", folderCoordinator: WebDAVFolderCoordinator? = nil) async throws -> String {
        try await uploadWithTarget(file: file, filename: filename, assetId: assetId, captureDate: captureDate, targets: targets, targetRoot: targetRoot, folderCoordinator: folderCoordinator).path
    }

    public func uploadWithTarget(file: URL, filename: String, assetId: String, captureDate: Date, targets: any UploadTargetProvider, targetRoot: String = "Photos/Apple Photos Connector", folderCoordinator: WebDAVFolderCoordinator? = nil) async throws -> UploadTarget {
        let folderCoordinator = folderCoordinator ?? runFolderCoordinator
        let identity = try ContentIdentity.read(file)
        let root = ["remote.php", "dav", "files", connection.user]
        let rootComponents = try Self.safeComponents(targetRoot)
        for count in 1...rootComponents.count {
            let components = Array(rootComponents.prefix(count))
            try await ensureCollection(root: root, components: components, coordinator: folderCoordinator)
        }
        for _ in 0..<100 {
            try Task.checkCancellation()
            let target = try await targets.prepare(identity: identity)
            let assetIdMatch = target.assetId == assetId
            let bytesMatch = target.bytes == identity.bytes
            let shaMatch = target.sha256 == identity.sha256
            let targetComponents = try Self.safeComponents(target.path)
            let pathPrefixMatch = Self.isValidTargetPath(target.path, under: targetRoot)
            let stateMatch = ["missing", "present", "contentAlreadyPresent"].contains(target.state)
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
            // A content reconciliation may legitimately point at the original
            // filename from another device.  The server has already verified
            // the bytes and path, so do not reject that target merely because
            // the local PhotoKit filename differs.
            if target.state == "contentAlreadyPresent" { return target }
            // Do not permit a server response to redirect uploads outside the fixed target directory.
            let names = try (0..<100).map { try Self.filename(filename, assetId: assetId, attempt: $0) }
            let filenameMatch = names.contains(target.path.split(separator: "/").last.map(String.init) ?? "")
            debug?("upload.prepare.validate.filename=\(filenameMatch)")
            guard filenameMatch else { throw UploadError.invalidResponse }
            if target.state == "present" || target.state == "contentAlreadyPresent" { return target }
            if targetComponents.count > rootComponents.count + 1 {
                for count in (rootComponents.count + 1)..<(targetComponents.count - 1) {
                    let components = Array(targetComponents.prefix(count))
                    try await ensureCollection(root: root, components: components, coordinator: folderCoordinator)
                }
            }
            var request = connection.request(path: root + targetComponents, method: "PUT")
            request.setValue("*", forHTTPHeaderField: "If-None-Match")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue(String(Int(captureDate.timeIntervalSince1970)), forHTTPHeaderField: "X-OC-MTime")
            debug?("Request PUT · path=\(request.url?.path ?? "") · fileBytes=\(identity.bytes)")
            debug?("upload.put.start")
            let putStarted = ContinuousClock.now
            debug?("APC IMPORT webdav.put START bytes=\(identity.bytes)")
            let response: DAVResponse
            do {
                response = try await transport.send(request, file: file)
                debug?("APC IMPORT webdav.put OK status=\(response.status) elapsed=\(putStarted.duration(to: .now)) bytes=\(identity.bytes)")
            } catch let error {
                let detail: String
                if let urlError = error as? URLError { detail = "urlError=\(urlError.code.rawValue)" }
                else if case let UploadError.http(status) = error { detail = "httpStatus=\(status)" }
                else { detail = "error=\(String(describing: type(of: error)))" }
                debug?("APC IMPORT webdav.put ERROR elapsed=\(putStarted.duration(to: .now)) \(detail)")
                throw error
            }
            debug?("upload.put.status=\(response.status)")
            debug?("Response PUT · status=\(response.status) · responseBytes=\(response.data.count)")
            if response.status == 201 { return target }
            // A concurrent successful PUT is rechecked by prepare. No speculative next filename.
            if response.status != 412 { throw UploadError.http(response.status) }
        }
        throw UploadError.collisions
    }

    private func ensureCollection(root: [String], components: [String], coordinator: WebDAVFolderCoordinator?) async throws {
        let path = (root + components).joined(separator: "/")
        if let coordinator, await coordinator.isEnsured(path: path) {
            debug?("APC IMPORT webdav.mkcol SKIP pathDepth=\(components.count) reason=alreadyEnsured")
            return
        }
        let operation: @Sendable () async throws -> Void = { [connection, transport, debug] in
            for attempt in 0..<3 {
                do {
                    let request = connection.request(path: root + components, method: "MKCOL")
                    debug?("Request MKCOL · path=\(request.url?.path ?? "")")
                    let mkcolStarted = ContinuousClock.now
                    debug?("APC IMPORT webdav.mkcol START pathDepth=\(components.count)")
                    let response: DAVResponse
                    do {
                        response = try await transport.send(request, file: nil)
                        debug?("APC IMPORT webdav.mkcol OK status=\(response.status) elapsed=\(mkcolStarted.duration(to: .now))")
                    } catch let error {
                        let detail: String
                        if let urlError = error as? URLError { detail = "urlError=\(urlError.code.rawValue)" }
                        else if case let UploadError.http(status) = error { detail = "httpStatus=\(status)" }
                        else { detail = "error=\(String(describing: type(of: error)))" }
                        debug?("APC IMPORT webdav.mkcol ERROR elapsed=\(mkcolStarted.duration(to: .now)) \(detail)")
                        throw error
                    }
                    debug?("Response MKCOL · status=\(response.status) · responseBytes=\(response.data.count)")
                    if response.status == 423 {
                        if attempt < 2 { try await Task.sleep(for: .milliseconds(100 * (attempt + 1))); continue }
                        throw UploadError.http(423)
                    }
                    guard [201, 405].contains(response.status) else { throw UploadError.http(response.status) }
                    return
                }
            }
        }
        if let coordinator { try await coordinator.ensure(path: path, operation: operation) }
        else { try await operation() }
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
