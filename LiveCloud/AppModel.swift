import Foundation
import Photos
import PhotosUI
import SwiftUI

/// One entry in the pCloud folder: a still and/or a video sharing the same base name.
struct CloudItem: Identifiable {
    let id: String
    let base: String
    var photoName: String?
    var videoName: String?
    var photoFileID: Int?
    var videoFileID: Int?
    /// The file to show as the thumbnail.
    var thumbFileID: Int? { photoFileID ?? videoFileID }
    var isLive: Bool { photoName != nil && videoName != nil }

    init(base: String, folderKey: String = "") {
        self.base = base
        self.id = folderKey.isEmpty ? base : "\(folderKey)/\(base)"
    }
}

enum CloudSource: String, CaseIterable, Identifiable {
    case liveCloud = "LiveCloud folder"
    case everywhere = "All Live Photos"
    var id: String { rawValue }
}

@MainActor
final class AppModel: ObservableObject {
    static let folder = "/LiveCloud"

    @Published var client: PCloudClient?
    @Published var items: [CloudItem] = []
    @Published var thumbnails: [Int: URL] = [:]
    @Published var source: CloudSource = .liveCloud
    @Published var busy = false
    @Published var status = ""

    private static let photoExts: Set<String> = ["heic", "heif", "jpg", "jpeg", "png"]
    private static let videoExts: Set<String> = ["mov", "mp4"]

    init() {
        if let host = KeychainStore.load("host"),
           let username = KeychainStore.load("username"),
           let password = KeychainStore.load("password") {
            client = PCloudClient(host: host, username: username, password: password)
        }
    }

    // MARK: Account

    func login(email: String, password: String, preferredHost: String) async {
        busy = true
        defer { busy = false }
        status = "Logging in…"
        do {
            let c = try await PCloudClient.login(email: email, password: password, preferredHost: preferredHost)
            KeychainStore.save(c.host, for: "host")
            KeychainStore.save(c.username, for: "username")
            KeychainStore.save(c.password, for: "password")
            try await c.ensureFolder(Self.folder)
            client = c
            status = ""
        } catch {
            status = error.localizedDescription
        }
    }

    func logout() {
        KeychainStore.delete("host")
        KeychainStore.delete("username")
        KeychainStore.delete("password")
        KeychainStore.delete("auth") // left over from older versions
        client = nil
        items = []
        appLog("Logged out")
    }

    // MARK: Upload

    func upload(_ selection: [PhotosPickerItem]) async {
        guard let client else { return }
        guard await ensurePhotoAccess() else {
            status = "Photos access denied. Allow full access in Settings › LiveCloud › Photos."
            return
        }

        let ids = selection.compactMap { $0.itemIdentifier }
        if ids.count < selection.count {
            appLog("Warning: \(selection.count - ids.count) item(s) had no identifier")
        }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var list: [PHAsset] = []
        assets.enumerateObjects { asset, _, _ in list.append(asset) }

        busy = true
        defer { busy = false }
        var done = 0
        for asset in list {
            status = "Uploading \(done + 1) of \(list.count)…"
            do {
                let files = try await LivePhotoFiles.export(asset: asset)
                try await client.upload(fileURL: files.photoURL, toFolder: Self.folder)
                try await client.upload(fileURL: files.videoURL, toFolder: Self.folder)
                appLog("Uploaded \(files.photoURL.lastPathComponent) + \(files.videoURL.lastPathComponent)")
                try? FileManager.default.removeItem(at: files.photoURL.deletingLastPathComponent())
                done += 1
            } catch {
                appLog("Upload failed: \(error.localizedDescription)")
            }
        }
        status = "Uploaded \(done) of \(list.count) Live Photo(s)."
    }

    // MARK: Browse & download

    func refresh() async {
        guard let client else { return }
        do {
            let groups: [String: CloudItem]
            switch source {
            case .liveCloud:
                groups = Self.group(try await client.listFiles(in: Self.folder), byFolder: false)
            case .everywhere:
                status = "Looking for Live Photos in all of pCloud…"
                // Only complete pairs (still + video with the same name in the same folder).
                groups = Self.group(try await client.listAllFiles(), byFolder: true).filter { $0.value.isLive }
                status = ""
            }
            items = groups.values.sorted { $0.base > $1.base }
            appLog("Found \(items.count) item(s) (\(source.rawValue))")

            // Thumbnails, in batches of 100.
            let ids = items.compactMap(\.thumbFileID)
            var links: [Int: URL] = [:]
            for start in stride(from: 0, to: ids.count, by: 100) {
                let batch = Array(ids[start..<min(start + 100, ids.count)])
                do {
                    links.merge(try await client.thumbnailURLs(fileids: batch)) { _, new in new }
                } catch {
                    appLog("Thumbnails failed: \(error.localizedDescription)")
                }
            }
            thumbnails = links
        } catch {
            status = error.localizedDescription
            appLog("List failed: \(error.localizedDescription)")
        }
    }

    /// Pairs files that share a name (IMG_1234.HEIC + IMG_1234.MOV) into one item.
    private static func group(_ files: [PCloudFile], byFolder: Bool) -> [String: CloudItem] {
        var groups: [String: CloudItem] = [:]
        for file in files {
            let ext = (file.name as NSString).pathExtension.lowercased()
            let base = (file.name as NSString).deletingPathExtension
            let folderKey = byFolder ? String(file.parentfolderid) : ""
            let key = "\(folderKey)/\(base)"
            var item = groups[key] ?? CloudItem(base: base, folderKey: folderKey)
            if photoExts.contains(ext) {
                item.photoName = file.name
                item.photoFileID = file.fileid
            } else if videoExts.contains(ext) {
                item.videoName = file.name
                item.videoFileID = file.fileid
            } else {
                continue
            }
            groups[key] = item
        }
        return groups
    }

    func saveToPhotos(_ items: [CloudItem]) async {
        var saved = 0
        for (i, item) in items.enumerated() {
            if items.count > 1 { appLog("Saving \(i + 1) of \(items.count)") }
            if await saveToPhotos(item) { saved += 1 }
        }
        if items.count > 1 {
            status = "Saved \(saved) of \(items.count) to Photos."
        }
    }

    @discardableResult
    func saveToPhotos(_ item: CloudItem) async -> Bool {
        guard let client else { return false }
        guard await ensurePhotoAccess() else {
            status = "Photos access denied."
            return false
        }
        busy = true
        defer { busy = false }
        status = "Downloading \(item.base)…"
        do {
            let dir = try LivePhotoFiles.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }

            if let p = item.photoName, let pid = item.photoFileID,
               let v = item.videoName, let vid = item.videoFileID {
                let photo = try await client.download(fileid: pid, name: p, to: dir)
                let video = try await client.download(fileid: vid, name: v, to: dir)
                try await LivePhotoFiles.saveLivePhoto(photo: photo, video: video)
                status = "Saved \(item.base) as a Live Photo."
            } else if let p = item.photoName, let pid = item.photoFileID {
                let photo = try await client.download(fileid: pid, name: p, to: dir)
                try await LivePhotoFiles.saveSingle(photo, isVideo: false)
                status = "Saved \(item.base) as a still (no video found)."
            } else if let v = item.videoName, let vid = item.videoFileID {
                let video = try await client.download(fileid: vid, name: v, to: dir)
                try await LivePhotoFiles.saveSingle(video, isVideo: true)
                status = "Saved \(item.base) as a video (no still found)."
            }
            appLog(status)
            return true
        } catch {
            status = "Save failed: \(error.localizedDescription)"
            appLog(status)
            return false
        }
    }

    // MARK: Permissions

    private func ensurePhotoAccess() async -> Bool {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current == .authorized { return true }
        if current == .notDetermined {
            let result = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            appLog("Photos permission: \(result.rawValue)")
            return result == .authorized
        }
        if current == .limited {
            appLog("Photos access is 'limited' — only photos you allowed can be uploaded.")
            return true
        }
        return false
    }
}