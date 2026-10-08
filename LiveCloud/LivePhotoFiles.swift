import Foundation
import Photos

/// Splits a Live Photo into its two original files, and puts two files back together.
enum LivePhotoFiles {
    struct Exported {
        let photoURL: URL
        let videoURL: URL
    }

    /// Exports the ORIGINAL still and paired video, unmodified.
    /// Originals are used even if the photo was edited, because their content
    /// identifiers are what make iOS recognise them as a pair.
    static func export(asset: PHAsset) async throws -> Exported {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let photo = resources.first(where: { $0.type == .photo }),
              let video = resources.first(where: { $0.type == .pairedVideo }) else {
            throw PCloudError(message: "Not a Live Photo (no paired video found)")
        }

        let base = baseName(for: asset, photo: photo)
        let photoExt = ext(of: photo.originalFilename, fallback: "HEIC")
        let videoExt = ext(of: video.originalFilename, fallback: "MOV")

        let dir = try makeTempDirectory()
        let photoURL = dir.appendingPathComponent("\(base).\(photoExt)")
        let videoURL = dir.appendingPathComponent("\(base).\(videoExt)")

        try await write(photo, to: photoURL)
        try await write(video, to: videoURL)
        return Exported(photoURL: photoURL, videoURL: videoURL)
    }

    /// Imports a still + video as one Live Photo. Photos pairs them only if
    /// the content identifiers inside both files still match.
    static func saveLivePhoto(photo: URL, video: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = true
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: photo, options: options)
            request.addResource(with: .pairedVideo, fileURL: video, options: options)
        }
    }

    /// Fallback for files that have no partner.
    static func saveSingle(_ url: URL, isVideo: Bool) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = true
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: isVideo ? .video : .photo, fileURL: url, options: options)
        }
    }

    static func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Helpers

    /// e.g. "20261008_141500_IMG_1234", so IMG_ numbers that repeat over the years don't collide.
    private static func baseName(for asset: PHAsset, photo: PHAssetResource) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let date = formatter.string(from: asset.creationDate ?? Date())
        let stem = (photo.originalFilename as NSString).deletingPathExtension
        return "\(date)_\(stem)"
    }

    private static func ext(of filename: String, fallback: String) -> String {
        let e = (filename as NSString).pathExtension
        return e.isEmpty ? fallback : e
    }

    private static func write(_ resource: PHAssetResource, to url: URL) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true // fetch from iCloud if "Optimize Storage" is on
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
