import CryptoKit
import Foundation
import Photos

enum PhoneFilter: String, CaseIterable, Identifiable {
    case photos = "Photos (not Live)"
    case live = "Live Photos"
    case videos = "Videos"
    case screenshots = "Screenshots"
    case all = "Everything"

    var id: String { rawValue }

    var predicate: NSPredicate? {
        let image = NSNumber(value: PHAssetMediaType.image.rawValue)
        let video = NSNumber(value: PHAssetMediaType.video.rawValue)
        let live = NSNumber(value: PHAssetMediaSubtype.photoLive.rawValue)
        let screenshot = NSNumber(value: PHAssetMediaSubtype.photoScreenshot.rawValue)
        switch self {
        case .photos:
            return NSPredicate(format: "mediaType == %@ AND (mediaSubtypes & %@) == 0", image, live)
        case .live:
            return NSPredicate(format: "mediaType == %@ AND (mediaSubtypes & %@) != 0", image, live)
        case .videos:
            return NSPredicate(format: "mediaType == %@", video)
        case .screenshots:
            return NSPredicate(format: "(mediaSubtypes & %@) != 0", screenshot)
        case .all:
            return nil
        }
    }
}

/// Holds a running SHA-1 so it can be updated from Photos' data callbacks,
/// which arrive one after another on a background queue.
final class HasherBox: @unchecked Sendable {
    private var hasher = Insecure.SHA1()
    private let lock = NSLock()

    func update(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        hasher.update(data: data)
    }

    func finalHex() -> String {
        lock.lock(); defer { lock.unlock() }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum BackupState {
    /// Every original file of the item has a same-size file in pCloud.
    case inCloud
    /// Live Photo whose still is in pCloud but whose video is not.
    case partial
    case missing
}

/// The iPhone's photo library, compared against pCloud.
///
/// Safety rule: an item is only deleted from the iPhone after its original
/// file(s) have been matched byte-for-byte (SHA-1) with a file in pCloud.
/// A same-size match is only used to *suggest* items, never to delete them.
@MainActor
final class PhoneLibrary: ObservableObject {
    @Published var filter: PhoneFilter = .photos {
        didSet { reload() }
    }
    @Published private(set) var assets: [PHAsset] = []
    /// Show only items whose files are already in pCloud.
    @Published var onlyInCloud = false

    var visibleAssets: [PHAsset] {
        onlyInCloud ? assets.filter { states[$0.localIdentifier] == .inCloud } : assets
    }
    @Published private(set) var states: [String: BackupState] = [:]
    @Published var selected: Set<String> = []
    @Published private(set) var busy = false
    @Published var status = ""

    /// pCloud file size → file ids with that size.
    private var cloudBySize: [Int64: [Int]] = [:]
    private var cloudIndexLoaded = false
    private var cloudSHA1: [Int: String] = [:]

    // MARK: Loading

    func start(client: PCloudClient?) async {
        guard await Self.ensureAccess() else {
            status = "Allow full Photos access in Settings › LiveCloud › Photos."
            return
        }
        reload()
        if let client, !cloudIndexLoaded {
            await checkBackups(client: client)
        }
    }

    func reload() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = filter.predicate
        let result = PHAsset.fetchAssets(with: options)
        var list: [PHAsset] = []
        list.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in list.append(asset) }
        assets = list
        let ids = Set(list.map(\.localIdentifier))
        selected = selected.intersection(ids)
        // Re-use the pCloud file list we already have, so switching filters needs no new "Check".
        if cloudIndexLoaded {
            Task { await compareWithCloud() }
        }
    }

    func state(of asset: PHAsset) -> BackupState? {
        states[asset.localIdentifier]
    }

    var inCloudCount: Int {
        assets.filter { states[$0.localIdentifier] == .inCloud }.count
    }

    // MARK: Compare with pCloud

    func checkBackups(client: PCloudClient) async {
        busy = true
        defer { busy = false }
        do {
            try await loadCloudIndex(client: client, force: true)
        } catch {
            status = "Couldn't read pCloud: \(error.localizedDescription)"
            appLog(status)
            return
        }
        await compareWithCloud()
    }

    /// Marks each asset in the current filter using the cached pCloud file list.
    private func compareWithCloud() async {
        status = "Comparing \(assets.count) items with pCloud…"
        let list = assets
        let index = cloudBySize
        let result = await Task.detached(priority: .userInitiated) { () -> [String: BackupState] in
            var out: [String: BackupState] = [:]
            for asset in list {
                out[asset.localIdentifier] = PhoneLibrary.sizeState(for: asset, index: index)
            }
            return out
        }.value
        states.merge(result) { _, new in new }
        let found = result.values.filter { $0 == .inCloud }.count
        let partial = result.values.filter { $0 == .partial }.count
        status = "\(found) of \(list.count) are already in pCloud."
            + (partial > 0 ? " \(partial) Live Photo(s) have only the still in pCloud." : "")
        appLog(status)
    }

    func selectAllInCloud() {
        selected = Set(assets.filter { states[$0.localIdentifier] == .inCloud }.map(\.localIdentifier))
    }

    func toggle(_ asset: PHAsset) {
        let id = asset.localIdentifier
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    // MARK: Delete

    /// Verifies each selected item against pCloud by checksum, then asks iOS to delete
    /// only the verified ones. iOS shows its own confirmation, and deleted items stay
    /// in "Recently Deleted" for 30 days.
    func deleteSelected(client: PCloudClient) async {
        let targets = assets.filter { selected.contains($0.localIdentifier) }
        guard !targets.isEmpty else { return }
        busy = true
        defer { busy = false }

        do {
            try await loadCloudIndex(client: client, force: false)
        } catch {
            status = "Couldn't read pCloud: \(error.localizedDescription)"
            return
        }

        var verified: [PHAsset] = []
        var notVerified = 0
        for (i, asset) in targets.enumerated() {
            status = "Checking \(i + 1) of \(targets.count) against pCloud…"
            if await verify(asset, client: client) {
                verified.append(asset)
            } else {
                notVerified += 1
                states[asset.localIdentifier] = .missing
                appLog("Not deleted (no exact copy in pCloud): \(Self.originalName(asset))")
            }
        }

        guard !verified.isEmpty else {
            status = "None of the \(targets.count) selected items have an exact copy in pCloud. Nothing was deleted."
            return
        }

        let toDelete = verified as NSArray
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(toDelete)
            }
            status = "Deleted \(verified.count) item(s) from your iPhone (they're in Recently Deleted for 30 days)."
                + (notVerified > 0 ? " \(notVerified) kept because no exact copy was found in pCloud." : "")
            appLog(status)
            selected.removeAll()
            reload()
        } catch {
            status = "Nothing deleted: \(error.localizedDescription)"
            appLog(status)
        }
    }

    // MARK: Internals

    private func loadCloudIndex(client: PCloudClient, force: Bool) async throws {
        if cloudIndexLoaded && !force { return }
        status = "Reading your pCloud file list…"
        let files = try await client.listAllFiles()
        var index: [Int64: [Int]] = [:]
        for file in files where file.size > 0 {
            index[file.size, default: []].append(file.fileid)
        }
        cloudBySize = index
        cloudIndexLoaded = true
        appLog("pCloud has \(files.count) files")
    }

    /// Checks every original resource of the asset by SHA-1 against same-size pCloud files.
    private func verify(_ asset: PHAsset, client: PCloudClient) async -> Bool {
        let resources = Self.originalResources(for: asset)
        guard !resources.isEmpty else { return false }
        for resource in resources {
            guard let size = Self.fileSize(resource),
                  let candidates = cloudBySize[size], !candidates.isEmpty else { return false }
            do {
                let local = try await Self.localSHA1(resource)
                var matched = false
                for fileid in candidates {
                    let remote: String
                    if let cached = cloudSHA1[fileid] {
                        remote = cached
                    } else {
                        remote = try await client.sha1(fileid: fileid)
                        cloudSHA1[fileid] = remote
                    }
                    if remote == local { matched = true; break }
                }
                if !matched { return false }
            } catch {
                appLog("Check failed for \(resource.originalFilename): \(error.localizedDescription)")
                return false
            }
        }
        return true
    }

    /// The unedited original files: still, video, or still + paired video for Live Photos.
    nonisolated static func originalResources(for asset: PHAsset) -> [PHAssetResource] {
        let all = PHAssetResource.assetResources(for: asset)
        var wanted: [PHAssetResourceType]
        switch asset.mediaType {
        case .video: wanted = [.video]
        case .image:
            wanted = [.photo]
            if asset.mediaSubtypes.contains(.photoLive) { wanted.append(.pairedVideo) }
        default: wanted = []
        }
        return wanted.compactMap { type in all.first { $0.type == type } }
    }

    nonisolated static func sizeState(for asset: PHAsset, index: [Int64: [Int]]) -> BackupState {
        let resources = originalResources(for: asset)
        guard !resources.isEmpty else { return .missing }
        let found = resources.map { r -> Bool in
            guard let size = fileSize(r) else { return false }
            return index[size] != nil
        }
        if found.allSatisfy({ $0 }) { return .inCloud }
        if asset.mediaSubtypes.contains(.photoLive), found.first == true { return .partial }
        return .missing
    }

    nonisolated static func fileSize(_ resource: PHAssetResource) -> Int64? {
        (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value
    }

    nonisolated static func originalName(_ asset: PHAsset) -> String {
        PHAssetResource.assetResources(for: asset).first?.originalFilename ?? asset.localIdentifier
    }

    /// Streams the file through SHA-1 without loading it into memory at once.
    nonisolated static func localSHA1(_ resource: PHAssetResource) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let box = HasherBox()
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true // fetch from iCloud if needed
            PHAssetResourceManager.default().requestData(for: resource, options: options) { data in
                box.update(data)
            } completionHandler: { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: box.finalHex())
                }
            }
        }
    }

    static func ensureAccess() async -> Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let result = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            return result == .authorized || result == .limited
        default:
            return false
        }
    }
}