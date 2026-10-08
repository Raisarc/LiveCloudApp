import CryptoKit
import Foundation

struct PCloudError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct PCloudFile {
    let fileid: Int
    let name: String
    let size: Int64
    let parentfolderid: Int

    init?(_ item: [String: Any]) {
        guard (item["isfolder"] as? Bool) != true,
              let fileid = item["fileid"] as? Int,
              let name = item["name"] as? String else { return nil }
        self.fileid = fileid
        self.name = name
        self.size = (item["size"] as? NSNumber)?.int64Value ?? 0
        self.parentfolderid = item["parentfolderid"] as? Int ?? -1
    }
}

/// Minimal client for the pCloud HTTP JSON API (https://docs.pcloud.com).
///
/// pCloud does not hand this app a login token, so every request is signed with
/// a fresh digest login instead: username + one-time digest + sha1 hash.
/// The password itself is never sent over the network.
struct PCloudClient {
    /// EU accounts live on eapi.pcloud.com, US accounts on api.pcloud.com.
    static let euHost = "eapi.pcloud.com"
    static let usHost = "api.pcloud.com"

    let host: String
    let username: String
    let password: String

    // MARK: Login

    /// Tries the preferred region first, then the other one, and reports both errors if both fail.
    static func login(email: String, password: String, preferredHost: String) async throws -> PCloudClient {
        let username = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hosts = preferredHost == euHost ? [euHost, usHost] : [usHost, euHost]
        var failures: [String] = []
        for host in hosts {
            let region = host == euHost ? "Europe" : "US"
            let client = PCloudClient(host: host, username: username, password: password)
            do {
                _ = try await client.get("userinfo", [:])
                appLog("Logged in via \(host)")
                return client
            } catch {
                appLog("Login via \(host) failed: \(error.localizedDescription)")
                failures.append("\(region): \(error.localizedDescription)")
            }
        }
        throw PCloudError(message: failures.joined(separator: "\n"))
    }

    // MARK: Folder operations

    func ensureFolder(_ path: String) async throws {
        _ = try await get("createfolderifnotexists", ["path": path])
    }

    func listFiles(in path: String) async throws -> [PCloudFile] {
        let json = try await get("listfolder", ["path": path])
        guard let metadata = json["metadata"] as? [String: Any],
              let contents = metadata["contents"] as? [[String: Any]] else {
            return []
        }
        return contents.compactMap(PCloudFile.init)
    }

    /// Every file in the account (all folders, not shared ones). Used to find what is already backed up.
    /// pCloud refuses a recursive listing of the top folder (error 1101), so the top
    /// folder is listed on its own and each folder in it is then listed recursively.
    func listAllFiles() async throws -> [PCloudFile] {
        var out: [PCloudFile] = []
        func walk(_ folder: [String: Any]) {
            for item in folder["contents"] as? [[String: Any]] ?? [] {
                if (item["isfolder"] as? Bool) == true {
                    walk(item)
                } else if let file = PCloudFile(item) {
                    out.append(file)
                }
            }
        }

        let rootJSON = try await get("listfolder", ["folderid": "0", "noshares": "1"])
        let topItems = (rootJSON["metadata"] as? [String: Any])?["contents"] as? [[String: Any]] ?? []
        for item in topItems {
            if (item["isfolder"] as? Bool) == true {
                guard let folderid = item["folderid"] as? Int else { continue }
                let name = item["name"] as? String ?? "?"
                do {
                    let json = try await get("listfolder", ["folderid": String(folderid), "recursive": "1", "noshares": "1"])
                    if let folder = json["metadata"] as? [String: Any] { walk(folder) }
                } catch {
                    appLog("Skipped folder \(name): \(error.localizedDescription)")
                }
            } else if let file = PCloudFile(item) {
                out.append(file)
            }
        }
        return out
    }

    /// SHA-1 of a file as computed by pCloud (available on both EU and US servers).
    func sha1(fileid: Int) async throws -> String {
        let json = try await get("checksumfile", ["fileid": String(fileid)])
        guard let sha1 = json["sha1"] as? String else {
            throw PCloudError(message: "No checksum for file \(fileid)")
        }
        return sha1.lowercased()
    }

    // MARK: Thumbnails

    /// Thumbnail links for up to ~100 files in one call. Files without a thumbnail are left out.
    func thumbnailURLs(fileids: [Int], size: String = "256x256") async throws -> [Int: URL] {
        guard !fileids.isEmpty else { return [:] }
        let json = try await get("getthumbslinks", [
            "fileids": fileids.map(String.init).joined(separator: ","),
            "size": size,
            "crop": "1",
        ])
        var out: [Int: URL] = [:]
        for thumb in json["thumbs"] as? [[String: Any]] ?? [] {
            guard (thumb["result"] as? Int) == 0,
                  let id = thumb["fileid"] as? Int,
                  let host = (thumb["hosts"] as? [String])?.first,
                  let path = thumb["path"] as? String,
                  let url = URL(string: "https://\(host)\(path)") else { continue }
            out[id] = url
        }
        return out
    }

    // MARK: Upload

    /// Uploads a file unchanged (byte for byte), which keeps the Live Photo pairing metadata intact.
    func upload(fileURL: URL, toFolder folder: String) async throws {
        var params = try await signedParams()
        params["path"] = folder
        params["nopartial"] = "1"

        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = host
        comps.path = "/uploadfile"
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps.url else { throw PCloudError(message: "Bad upload URL") }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let name = fileURL.lastPathComponent
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\n".utf8))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(try Data(contentsOf: fileURL))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        let (data, _) = try await URLSession.shared.upload(for: request, from: body)
        _ = try Self.parse(data)
    }

    // MARK: Download

    /// Downloads a file into `directory`, keeping its original name (the extension matters to Photos).
    func download(name: String, inFolder folder: String, to directory: URL) async throws -> URL {
        try await download(linkParams: ["path": "\(folder)/\(name)"], name: name, to: directory)
    }

    /// Same, but by file id, so it works for files in any folder.
    func download(fileid: Int, name: String, to directory: URL) async throws -> URL {
        try await download(linkParams: ["fileid": String(fileid)], name: name, to: directory)
    }

    private func download(linkParams: [String: String], name: String, to directory: URL) async throws -> URL {
        var params = linkParams
        params["forcedownload"] = "1"
        let json = try await get("getfilelink", params)
        guard let hosts = json["hosts"] as? [String],
              let linkHost = hosts.first,
              let path = json["path"] as? String,
              let url = URL(string: "https://\(linkHost)\(path)") else {
            throw PCloudError(message: "No download link for \(name)")
        }

        let (tempURL, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw PCloudError(message: "Download of \(name) failed (HTTP \(http.statusCode))")
        }
        let destination = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }

    // MARK: Plumbing

    /// username + a fresh one-time digest + passworddigest = sha1(password + sha1(username) + digest)
    private func signedParams() async throws -> [String: String] {
        let json = try await Self.call(host: host, method: "getdigest", params: [:])
        guard let digest = json["digest"] as? String else {
            throw PCloudError(message: "No digest returned")
        }
        return [
            "username": username,
            "digest": digest,
            "passworddigest": Self.sha1Hex(password + Self.sha1Hex(username) + digest),
        ]
    }

    private func get(_ method: String, _ params: [String: String]) async throws -> [String: Any] {
        var all = try await signedParams()
        all.merge(params) { _, new in new }
        return try await Self.call(host: host, method: method, params: all)
    }

    private static func call(host: String, method: String, params: [String: String]) async throws -> [String: Any] {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = host
        comps.path = "/\(method)"
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps.url else { throw PCloudError(message: "Bad URL") }
        let (data, _) = try await URLSession.shared.data(from: url)
        return try parse(data)
    }

    private static func parse(_ data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PCloudError(message: "Unexpected response from pCloud")
        }
        let result = json["result"] as? Int ?? -1
        guard result == 0 else {
            let text = json["error"] as? String ?? "unknown error"
            throw PCloudError(message: "pCloud error \(result): \(text)")
        }
        return json
    }

    private static func sha1Hex(_ text: String) -> String {
        Insecure.SHA1.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}