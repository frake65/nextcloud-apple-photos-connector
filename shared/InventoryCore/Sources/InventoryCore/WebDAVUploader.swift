import Foundation
import Darwin

private enum DAVDiagnostics {
    static let enabled = ProcessInfo.processInfo.environment["APC_UPLOAD_DIAGNOSTICS"] == "1"
    static func log(_ phase: String, bytes: Int64? = nil) {
        guard enabled else { return }
        var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
        let rss = result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
        print("APC_UPLOAD_DIAGNOSTIC phase=\(phase) rssBytes=\(rss)\(bytes.map { " bytes=\($0)" } ?? "")")
    }
}

public struct DAVResponse: Sendable {
    public let status: Int
    public let data: Data
    public let headers: [String: String]
    public let requestMethod: String?
    public let requestPath: String?
    public init(status: Int, data: Data = Data(), headers: [String: String] = [:], requestMethod: String? = nil, requestPath: String? = nil) {
        self.status = status; self.data = data; self.headers = headers; self.requestMethod = requestMethod; self.requestPath = requestPath
    }
}

public enum DAVRequestKind: Sendable {
    case api
    case longRunningVerification
    case fileTransfer
}

public protocol DAVTransport: Sendable {
    func send(_ request: URLRequest, file: URL?) async throws -> DAVResponse
    func send(_ request: URLRequest, file: URL?, progress: (@Sendable (Int64, Int64) -> Void)?) async throws -> DAVResponse
    func send(_ request: URLRequest, file: URL?, kind: DAVRequestKind, progress: (@Sendable (Int64, Int64) -> Void)?) async throws -> DAVResponse
}

public extension DAVTransport {
    func send(_ request: URLRequest, file: URL?, progress: (@Sendable (Int64, Int64) -> Void)?) async throws -> DAVResponse {
        try await send(request, file: file, kind: file == nil ? .api : .fileTransfer, progress: progress)
    }
    func send(_ request: URLRequest, file: URL?, kind: DAVRequestKind, progress: (@Sendable (Int64, Int64) -> Void)?) async throws -> DAVResponse {
        try await send(request, file: file, progress: progress)
    }
}

/// Redirects are rejected, including same-origin redirects, to preserve conditional PUT semantics.
public final class NetworkTransport: NSObject, DAVTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private static let requestTimeout: TimeInterval = 20
    public static func timeout(for kind: DAVRequestKind) -> (request: TimeInterval, resource: TimeInterval) {
        switch kind {
        case .api: (20, 30)
        case .longRunningVerification, .fileTransfer: (1800, 1800)
        }
    }
    private var apiSession: URLSession!
    private var verificationSession: URLSession!
    private var transferSession: URLSession!
    private let progressLock = NSLock()
    private var progressHandlers: [Int: @Sendable (Int64, Int64) -> Void] = [:]
    private var connectivityWaitingHandler: (@Sendable (Bool) -> Void)?
    private let responseDiagnostics: (@Sendable (DAVResponse) -> Void)?

    public override convenience init() {
        self.init(allowsCellularAccess: true, waitsForConnectivity: false, responseDiagnostics: nil)
    }

    public init(allowsCellularAccess: Bool, waitsForConnectivity: Bool, responseDiagnostics: (@Sendable (DAVResponse) -> Void)? = nil) {
        self.responseDiagnostics = responseDiagnostics
        let apiConfiguration = URLSessionConfiguration.ephemeral
        apiConfiguration.httpCookieStorage = nil
        apiConfiguration.timeoutIntervalForRequest = Self.timeout(for: .api).request
        apiConfiguration.timeoutIntervalForResource = Self.timeout(for: .api).resource
        apiConfiguration.allowsCellularAccess = allowsCellularAccess
        apiConfiguration.waitsForConnectivity = waitsForConnectivity
        let transferConfiguration = URLSessionConfiguration.ephemeral
        transferConfiguration.httpCookieStorage = nil
        transferConfiguration.timeoutIntervalForRequest = Self.timeout(for: .fileTransfer).request
        transferConfiguration.timeoutIntervalForResource = Self.timeout(for: .fileTransfer).resource
        transferConfiguration.allowsCellularAccess = allowsCellularAccess
        transferConfiguration.waitsForConnectivity = waitsForConnectivity
        let verificationConfiguration = URLSessionConfiguration.ephemeral
        verificationConfiguration.httpCookieStorage = nil
        verificationConfiguration.timeoutIntervalForRequest = Self.timeout(for: .longRunningVerification).request
        verificationConfiguration.timeoutIntervalForResource = Self.timeout(for: .longRunningVerification).resource
        verificationConfiguration.allowsCellularAccess = allowsCellularAccess
        verificationConfiguration.waitsForConnectivity = waitsForConnectivity
        super.init()
        apiSession = URLSession(configuration: apiConfiguration, delegate: self, delegateQueue: nil)
        verificationSession = URLSession(configuration: verificationConfiguration, delegate: self, delegateQueue: nil)
        transferSession = URLSession(configuration: transferConfiguration, delegate: self, delegateQueue: nil)
    }

    deinit {
        apiSession?.invalidateAndCancel()
        verificationSession?.invalidateAndCancel()
        transferSession?.invalidateAndCancel()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progressLock.lock(); let handler = progressHandlers[task.taskIdentifier]; progressLock.unlock()
        progressLock.lock(); let waitingHandler = connectivityWaitingHandler; progressLock.unlock()
        waitingHandler?(false)
        handler?(totalBytesSent, totalBytesExpectedToSend)
    }
    public func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        progressLock.lock(); let waitingHandler = connectivityWaitingHandler; progressLock.unlock()
        waitingHandler?(true)
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        progressLock.lock(); progressHandlers.removeValue(forKey: task.taskIdentifier); let waitingHandler = connectivityWaitingHandler; progressLock.unlock()
        waitingHandler?(false)
    }
    public func setConnectivityWaitingHandler(_ handler: (@Sendable (Bool) -> Void)?) {
        progressLock.lock(); connectivityWaitingHandler = handler; progressLock.unlock()
    }
    public func send(_ request: URLRequest, file: URL?) async throws -> DAVResponse {
        try await send(request, file: file, kind: file == nil ? .api : .fileTransfer, progress: nil)
    }
    public func send(_ request: URLRequest, file: URL?, progress: (@Sendable (Int64, Int64) -> Void)?) async throws -> DAVResponse {
        try await send(request, file: file, kind: file == nil ? .api : .fileTransfer, progress: progress)
    }
    public func send(_ request: URLRequest, file: URL?, kind: DAVRequestKind, progress: (@Sendable (Int64, Int64) -> Void)?) async throws -> DAVResponse {
        let session: URLSession = switch kind {
        case .api: apiSession!
        case .longRunningVerification: verificationSession!
        case .fileTransfer: transferSession!
        }
        var request = request
        request.timeoutInterval = kind == .api ? Self.requestTimeout : 1800
        let result: (Data, URLResponse)
        if let file { result = try await upload(session: session, request: request, file: file, progress: progress) }
        else { result = try await session.data(for: request) }
        guard let response = result.1 as? HTTPURLResponse else { throw UploadError.invalidResponse }
        var headers: [String: String] = [:]; for (key, value) in response.allHeaderFields { headers[String(describing: key)] = String(describing: value) }
        // WebDAV commonly answers MKCOL for an already existing directory
        // with 405. The caller explicitly treats that as successful/idempotent.
        // Preserve all other HTTP errors for normal error handling.
        let expectedExistingDirectory = request.httpMethod == "MKCOL" && response.statusCode == 405
        let davResponse = DAVResponse(status: response.statusCode, data: result.0, headers: headers, requestMethod: request.httpMethod, requestPath: request.url?.path)
        responseDiagnostics?(davResponse)
        if response.statusCode >= 400 && !expectedExistingDirectory {
            throw UploadError.http(response.statusCode)
        }
        return davResponse
    }

    private func upload(session: URLSession, request: URLRequest, file: URL, progress: (@Sendable (Int64, Int64) -> Void)?) async throws -> (Data, URLResponse) {
        DAVDiagnostics.log("webdav.put.request-created")
        let fileBytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
        DAVDiagnostics.log("webdav.put.file-open", bytes: fileBytes)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), any Error>) in
            let task = session.uploadTask(with: request, fromFile: file) { data, response, error in
                if let error { DAVDiagnostics.log("webdav.put.complete"); continuation.resume(throwing: error) }
                else if let response {
                    DAVDiagnostics.log("webdav.put.response-received")
                    let responseData = data ?? Data()
                    DAVDiagnostics.log("webdav.put.response-body-read", bytes: Int64(responseData.count))
                    DAVDiagnostics.log("webdav.put.complete")
                    continuation.resume(returning: (responseData, response))
                } else { DAVDiagnostics.log("webdav.put.complete"); continuation.resume(throwing: UploadError.invalidResponse) }
            }
            DAVDiagnostics.log("webdav.put.uploadtask-created")
            if let progress {
                progressLock.lock(); progressHandlers[task.taskIdentifier] = progress; progressLock.unlock()
            }
            task.resume()
            DAVDiagnostics.log("webdav.put.uploadtask-resumed")
        }
    }
}

public struct ServerErrorInfo: Codable, Sendable, Equatable {
    public let status: Int
    public let message: String?
    public let code: String?
    public let runId: String?
    public init(status: Int, message: String? = nil, code: String? = nil, runId: String? = nil) {
        self.status = status; self.message = message; self.code = code; self.runId = runId
    }
    public var isRetryable: Bool { status == 409 || status == 503 }
}

public enum UploadError: LocalizedError {
    case invalidConfiguration, invalidFilename, invalidResponse, networkUnavailable, http(Int), server(ServerErrorInfo), diagnostic(String), collisions
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Gültige HTTPS-Serveradresse und Zugangsdaten erforderlich."
        case .invalidFilename: "Originaldateiname fehlt oder ist für den Upload nicht zulässig."
        case .invalidResponse: "Unerwartete Serverantwort."
        case .networkUnavailable: "Upload wartet auf WLAN."
        case .http(let code): "Serveranfrage fehlgeschlagen (HTTP \(code))."
        case .server(let error): error.message ?? "Serveranfrage fehlgeschlagen (HTTP \(error.status))."
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
        try self.init(server: server, authUser: user, davUser: user, password: password)
    }
    public init(server: String, authUser: String, davUser: String, password: String) throws {
        guard let url = URL(string: server), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !authUser.isEmpty, !authUser.contains(":"), !authUser.contains("/"),
              !davUser.isEmpty, !davUser.contains(":"), !davUser.contains("/"), !password.isEmpty else { throw UploadError.invalidConfiguration }
        base = url; user = davUser
        authorization = "Basic " + Data("\(authUser):\(password)".utf8).base64EncodedString()
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

    public func uploadWithTarget(file: URL, filename: String, assetId: String, captureDate: Date, targets: any UploadTargetProvider, targetRoot: String = "Photos/Apple Photos Connector", folderCoordinator: WebDAVFolderCoordinator? = nil, progress: (@Sendable (Int64, Int64) -> Void)? = nil, contentIdentityDiagnostics: (@Sendable (ContentIdentity.ReadDiagnosticEvent) -> Void)? = nil, contentIdentity: ContentIdentity? = nil) async throws -> UploadTarget {
        let folderCoordinator = folderCoordinator ?? runFolderCoordinator
        let identity: ContentIdentity
        if let contentIdentity {
            identity = contentIdentity
        } else {
            #if DEBUG
            identity = try ContentIdentity.read(file, diagnostics: contentIdentityDiagnostics)
            #else
            identity = try ContentIdentity.read(file)
            #endif
        }
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
                response = try await transport.send(request, file: file, progress: progress)
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
