import CryptoKit
import Foundation

struct PCloudError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct PCloudFile {
    let name: String
    let size: Int
}

/// Minimal client for the pCloud HTTP JSON API (https://docs.pcloud.com).
struct PCloudClient {
    /// EU accounts live on eapi.pcloud.com, US accounts on api.pcloud.com.
    static let euHost = "eapi.pcloud.com"
    static let usHost = "api.pcloud.com"

    let host: String
    let auth: String

    // MARK: Login

    /// Tries the preferred region first, then the other one, and reports both errors if both fail.
    /// Uses pCloud's digest login, so the password itself is never sent.
    static func login(email: String, password: String, preferredHost: String) async throws -> PCloudClient {
        let username = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hosts = preferredHost == euHost ? [euHost, usHost] : [usHost, euHost]
        var failures: [String] = []
        for host in hosts {
            let region = host == euHost ? "Europe" : "US"
            do {
                let digestJSON = try await call(host: host, method: "getdigest", params: [:], usePOST: false)
                guard let digest = digestJSON["digest"] as? String else {
                    throw PCloudError(message: "No digest returned")
                }
                // passworddigest = sha1(password + sha1(lowercase username) + digest)
                let passwordDigest = sha1Hex(password + sha1Hex(username) + digest)
                let json = try await call(host: host, method: "userinfo", params: [
                    "getauth": "1",
                    "logout": "1",
                    "username": username,
                    "digest": digest,
                    "passworddigest": passwordDigest,
                ], usePOST: false) // safe as GET: only a hash is sent, never the password
                if let auth = json["auth"] as? String {
                    appLog("Logged in via \(host)")
                    return PCloudClient(host: host, auth: auth)
                }
                let keys = json.keys.sorted().joined(separator: ", ")
                failures.append("\(region): no token returned (response had: \(keys))")
            } catch {
                appLog("Login via \(host) failed: \(error.localizedDescription)")
                failures.append("\(region): \(error.localizedDescription)")
            }
        }
        throw PCloudError(message: failures.joined(separator: "\n"))
    }

    private static func sha1Hex(_ text: String) -> String {
        Insecure.SHA1.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
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
        return contents.compactMap { item in
            guard (item["isfolder"] as? Bool) != true,
                  let name = item["name"] as? String else { return nil }
            return PCloudFile(name: name, size: item["size"] as? Int ?? 0)
        }
    }

    // MARK: Upload

    /// Uploads a file unchanged (byte for byte), which keeps the Live Photo pairing metadata intact.
    func upload(fileURL: URL, toFolder folder: String) async throws {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = host
        comps.path = "/uploadfile"
        comps.queryItems = [
            URLQueryItem(name: "auth", value: auth),
            URLQueryItem(name: "path", value: folder),
            URLQueryItem(name: "nopartial", value: "1"),
        ]
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
        let json = try await get("getfilelink", ["path": "\(folder)/\(name)", "forcedownload": "1"])
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

    private func get(_ method: String, _ params: [String: String]) async throws -> [String: Any] {
        var all = params
        all["auth"] = auth
        return try await Self.call(host: host, method: method, params: all, usePOST: false)
    }

    private static func call(host: String, method: String, params: [String: String], usePOST: Bool) async throws -> [String: Any] {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = host
        comps.path = "/\(method)"

        var request: URLRequest
        if usePOST {
            // POST keeps the password out of the URL.
            guard let url = comps.url else { throw PCloudError(message: "Bad URL") }
            request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(formEncode(params).utf8)
        } else {
            comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let url = comps.url else { throw PCloudError(message: "Bad URL") }
            request = URLRequest(url: url)
        }

        let (data, _) = try await URLSession.shared.data(for: request)
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

    private static func formEncode(_ params: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return params.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }
}