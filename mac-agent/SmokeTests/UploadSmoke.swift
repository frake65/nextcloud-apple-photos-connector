import Foundation

/// Simulated remote state is durable and independent of the client process.
actor FakeDAV: DAVTransport, UploadTargetProvider {
    enum Mode { case normal, failed, lostResponse, unclearResponse }
    struct Reservation: Codable { let attempt: Int; let identity: ContentIdentity }
    let directory: URL
    let mode: Mode
    init(directory: URL, mode: Mode = .normal) { self.directory = directory; self.mode = mode }
    func prepare(identity: ContentIdentity) async throws -> UploadTarget {
        let reservationURL = directory.appendingPathComponent("reservation.json")
        var attempt = 0
        if FileManager.default.fileExists(atPath: reservationURL.path) {
            let saved = try JSONDecoder().decode(Reservation.self, from: Data(contentsOf: reservationURL))
            precondition(saved.identity == identity)
            attempt = saved.attempt
            let name = try WebDAVUploader.filename("photo.jpg", assetId: "42", attempt: attempt)
            let existing = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: existing.path) {
                return UploadTarget(assetId: "42", path: "Photos/Apple Photos Connector/" + name, identity: identity, state: "missing")
            }
            if try ContentIdentity.read(existing) == identity {
                return UploadTarget(assetId: "42", path: "Photos/Apple Photos Connector/" + name, identity: identity, state: "present")
            }
            attempt += 1
        }
        for candidate in attempt..<100 {
            let name = try WebDAVUploader.filename("photo.jpg", assetId: "42", attempt: candidate)
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) { continue }
            try JSONEncoder().encode(Reservation(attempt: candidate, identity: identity)).write(to: reservationURL, options: .atomic)
            return UploadTarget(assetId: "42", path: "Photos/Apple Photos Connector/" + name, identity: identity, state: "missing")
        }
        throw UploadError.collisions
    }
    func send(_ request: URLRequest, file: URL?) async throws -> DAVResponse {
        if request.httpMethod == "MKCOL" { return DAVResponse(status: 405) }
        precondition(request.httpMethod == "PUT", "No DELETE allowed")
        precondition(request.value(forHTTPHeaderField: "If-None-Match") == "*", "Every PUT must be create-only")
        let countURL = directory.appendingPathComponent("put-count")
        let count = (try? String(contentsOf: countURL, encoding: .utf8)).flatMap(Int.init) ?? 0
        try String(count + 1).write(to: countURL, atomically: true, encoding: .utf8)
        if mode == .failed { return DAVResponse(status: 503) }
        let target = directory.appendingPathComponent(request.url!.lastPathComponent)
        if FileManager.default.fileExists(atPath: target.path) { return DAVResponse(status: 412) }
        try Data(contentsOf: file!).write(to: target, options: .withoutOverwriting)
        if mode == .lostResponse { throw URLError(.networkConnectionLost) }
        if mode == .unclearResponse { return DAVResponse(status: 503) }
        return DAVResponse(status: 201)
    }
}

@main struct UploadSmoke {
    static func main() async throws {
        let connection = try ConnectorConnection(server: "https://example.invalid/nextcloud", user: "test", password: "test")
        let root: URL
        let action = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "normal"
        if CommandLine.arguments.count > 2 { root = URL(fileURLWithPath: CommandLine.arguments[2]) }
        else {
            root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/upload-test-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        let file = root.appendingPathComponent("local-original")
        if !FileManager.default.fileExists(atPath: file.path) { try Data("ORIGINAL".utf8).write(to: file) }
        if action == "lost" {
            let remote = FakeDAV(directory: root, mode: .lostResponse)
            do { _ = try await WebDAVUploader(connection: connection, transport: remote).upload(file: file, filename: "photo.jpg", assetId: "42", targets: remote); fatalError("Expected lost response") }
            catch is URLError {}
            let saved = try Data(contentsOf: root.appendingPathComponent("photo.jpg"))
            precondition(saved == Data("ORIGINAL".utf8))
            print("PASS: PUT persisted original, response lost; client exits without success receipt")
            return
        }
        if action == "recover" {
            let remote = FakeDAV(directory: root)
            let path = try await WebDAVUploader(connection: connection, transport: remote).upload(file: file, filename: "photo.jpg", assetId: "42", targets: remote)
            let count = try String(contentsOf: root.appendingPathComponent("put-count"), encoding: .utf8)
            precondition(path == "Photos/Apple Photos Connector/photo.jpg" && count == "1")
            print("PASS: separate client process recovers existing file with no second PUT or duplicate")
            return
        }
        try Data("FOREIGN!".utf8).write(to: root.appendingPathComponent("photo.jpg"))
        try Data("COLLIDE!".utf8).write(to: root.appendingPathComponent("photo--apc-42.jpg"))
        let remote = FakeDAV(directory: root)
        let path = try await WebDAVUploader(connection: connection, transport: remote).upload(file: file, filename: "photo.jpg", assetId: "42", targets: remote)
        let original = try Data(contentsOf: root.appendingPathComponent("photo.jpg"))
        let collision = try Data(contentsOf: root.appendingPathComponent("photo--apc-42.jpg"))
        precondition(path == "Photos/Apple Photos Connector/photo--apc-42-1.jpg" && original == Data("FOREIGN!".utf8) && collision == Data("COLLIDE!".utf8))
        print("PASS: same-size foreign files and occupied suffixes remain unchanged")
        for mode in [FakeDAV.Mode.failed, .unclearResponse] {
            let folder = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let broken = FakeDAV(directory: folder, mode: mode)
            do { _ = try await WebDAVUploader(connection: connection, transport: broken).upload(file: file, filename: "photo.jpg", assetId: "42", targets: broken); fatalError("Expected HTTP error") }
            catch UploadError.http(503) {}
            let resumed = FakeDAV(directory: folder)
            _ = try await WebDAVUploader(connection: connection, transport: resumed).upload(file: file, filename: "photo.jpg", assetId: "42", targets: resumed)
            let count = try String(contentsOf: folder.appendingPathComponent("put-count"), encoding: .utf8)
            precondition(count == (mode == .failed ? "2" : "1"))
        }
        print("PASS: failed PUT retries; successful PUT with misleading HTTP error recovers without reupload")
        let vector = root.appendingPathComponent("sha256-vector")
        try Data("abc".utf8).write(to: vector)
        let digest = try ContentIdentity.read(vector)
        precondition(digest.bytes == 3 && digest.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let encodedURL = connection.request(path: ["remote.php", "dav", "files", "test", "Original ü #%.HEIC"], method: "PUT").url!
        precondition(encodedURL.lastPathComponent == "Original ü #%.HEIC" && encodedURL.fragment == nil)
        for invalid in ["../photo.jpg", "a/b.jpg", "a\\b.jpg", "", ".", ".."] {
            do { _ = try WebDAVUploader.filename(invalid, assetId: "42", attempt: 0); fatalError("Unsafe filename accepted") }
            catch UploadError.invalidFilename {}
        }
        do { _ = try ConnectorConnection(server: "http://example.invalid", user: "test", password: "test"); fatalError("HTTP accepted") }
        catch UploadError.invalidConfiguration {}
        print("PASS: SHA-256 known vector, URL encoding, filename and HTTPS validation")
    }
}
