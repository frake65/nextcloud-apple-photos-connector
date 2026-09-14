import Foundation
import InventoryCore

struct UploadFailure: Error, Sendable, Equatable {
    enum Stage: String, Sendable { case inventory, export, preparation, folder, target, put, completion, receipt }
    enum Category: String, Sendable { case timeout, network, authorization, notFound, tooLarge, storageFull, server, http, source, filesystem, response, unknown }
    let stage: Stage
    let category: Category
    let httpStatus: Int?
    let technicalDetail: String

    static func capture(_ error: any Error, stage: Stage) -> Self {
        if let failure = error as? Self { return failure }
        let ns = error as NSError
        let status: Int?
        if case let UploadError.http(code) = error { status = code } else { status = nil }
        let category: Category
        if let status {
            switch status {
            case 401, 403: category = .authorization
            case 404: category = .notFound
            case 413: category = .tooLarge
            case 507: category = .storageFull
            case 500...599: category = .server
            default: category = .http
            }
        } else if ns.domain == NSCocoaErrorDomain { category = .filesystem }
        else if stage == .export { category = .source }
        else if ns.domain == NSURLErrorDomain { category = ns.code == NSURLErrorTimedOut ? .timeout : .network }
        else if error is DecodingError { category = .response }
        else if case UploadError.invalidResponse = error { category = .response }
        else { category = .unknown }
        // Keep structured diagnostics, never response bodies, credentials or URLs.
        return Self(stage: stage, category: category, httpStatus: status,
                    technicalDetail: "stage=\(stage.rawValue) domain=\(ns.domain) code=\(ns.code)" + (status.map { " HTTP \($0)" } ?? ""))
    }

    var userMessage: String {
        let key: String
        switch category {
        case .timeout: key = "uploadFailureTimeout"
        case .network: key = "uploadFailureNetwork"
        case .authorization: key = "uploadFailureAuthorization"
        case .notFound: key = stage == .put || stage == .folder ? "uploadFailureTargetMissing" : "uploadFailureEndpointMissing"
        case .tooLarge: key = "uploadFailureTooLarge"
        case .storageFull: key = "uploadFailureStorageFull"
        case .server: key = "uploadFailureServer"
        case .http: key = "uploadFailureHTTP"
        case .source: key = "uploadFailureSource"
        case .filesystem: key = "uploadFailureFilesystem"
        case .response: key = "uploadFailureResponse"
        case .unknown: key = "uploadFailureUnknown"
        }
        let message = category == .http ? L10n.format(key, httpStatus ?? 0) : L10n.text(key)
        if stage == .completion || stage == .receipt {
            return L10n.text("uploadFailureConfirmation") + " " + message
        }
        return message
    }
}

/// Preserve request context while leaving DAV success/error semantics unchanged.
struct UploadDisplayTransport: DAVTransport {
    let base: any DAVTransport
    func send(_ request: URLRequest, file: URL?) async throws -> DAVResponse {
        let stage: UploadFailure.Stage = request.httpMethod == "MKCOL" ? .folder : .put
        do {
            let response = try await base.send(request, file: file)
            // WebDAVUploader interprets these statuses, including MKCOL 405 and PUT 412.
            if response.status >= 400 && !(request.httpMethod == "MKCOL" && (response.status == 405 || response.status == 423))
                && !(request.httpMethod == "PUT" && response.status == 412) {
                throw UploadError.http(response.status)
            }
            return response
        } catch is CancellationError { throw CancellationError() }
        catch { throw UploadFailure.capture(error, stage: stage) }
    }
}
