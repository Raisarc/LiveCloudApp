import AVKit
import Photos
import PhotosUI
import SwiftUI

/// What the long-press preview is showing.
enum PreviewContent {
    case live(PHLivePhoto)
    case video(AVPlayer)
    case image(UIImage)
}

/// Loads a preview for a phone asset or a pCloud item and drives the preview sheet.
@MainActor
final class Previewer: ObservableObject {
    @Published var isShown = false
    @Published private(set) var title = ""
    @Published private(set) var content: PreviewContent?
    @Published private(set) var message = ""
    private var token = UUID()

    /// Preview something from the iPhone's library.
    func show(asset: PHAsset) {
        let current = begin(title: PhoneLibrary.originalName(asset))
        let manager = PHImageManager.default()

        if asset.mediaSubtypes.contains(.photoLive) {
            let options = PHLivePhotoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            manager.requestLivePhoto(for: asset, targetSize: PHImageManagerMaximumSize,
                                     contentMode: .aspectFit, options: options) { livePhoto, _ in
                guard let livePhoto else { return }
                Task { @MainActor in self.set(.live(livePhoto), for: current) }
            }
        } else if asset.mediaType == .video {
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            manager.requestPlayerItem(forVideo: asset, options: options) { item, _ in
                guard let item else { return }
                Task { @MainActor in self.set(.video(AVPlayer(playerItem: item)), for: current) }
            }
        } else {
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            manager.requestImage(for: asset, targetSize: CGSize(width: 2000, height: 2000),
                                 contentMode: .aspectFit, options: options) { image, _ in
                guard let image else { return }
                Task { @MainActor in self.set(.image(image), for: current) }
            }
        }
    }

    /// Preview something stored in pCloud (downloads it first).
    func show(item: CloudItem, client: PCloudClient) {
        let current = begin(title: item.base)
        message = "Downloading…"
        Task {
            do {
                let dir = try LivePhotoFiles.makeTempDirectory()
                if let p = item.photoName, let pid = item.photoFileID,
                   let v = item.videoName, let vid = item.videoFileID {
                    let photo = try await client.download(fileid: pid, name: p, to: dir)
                    let video = try await client.download(fileid: vid, name: v, to: dir)
                    PHLivePhoto.request(withResourceFileURLs: [photo, video], placeholderImage: nil,
                                        targetSize: .zero, contentMode: .aspectFit) { livePhoto, info in
                        if let livePhoto {
                            Task { @MainActor in self.set(.live(livePhoto), for: current) }
                        } else if let error = info[PHLivePhotoInfoErrorKey] as? Error {
                            Task { @MainActor in self.fail(error.localizedDescription, for: current) }
                        }
                    }
                } else if let v = item.videoName, let vid = item.videoFileID {
                    let video = try await client.download(fileid: vid, name: v, to: dir)
                    set(.video(AVPlayer(url: video)), for: current)
                } else if let p = item.photoName, let pid = item.photoFileID {
                    let photo = try await client.download(fileid: pid, name: p, to: dir)
                    if let image = UIImage(contentsOfFile: photo.path) {
                        set(.image(image), for: current)
                    } else {
                        fail("Couldn't open the photo.", for: current)
                    }
                }
            } catch {
                fail(error.localizedDescription, for: current)
            }
        }
    }

    func close() {
        if case .video(let player) = content { player.pause() }
        token = UUID()
        content = nil
    }

    private func begin(title: String) -> UUID {
        close()
        self.title = title
        message = ""
        isShown = true
        let new = UUID()
        token = new
        return new
    }

    private func set(_ content: PreviewContent, for current: UUID) {
        guard current == token else { return }
        message = ""
        self.content = content
    }

    private func fail(_ text: String, for current: UUID) {
        guard current == token else { return }
        message = "Couldn't load preview: \(text)"
        appLog(message)
    }
}

struct PreviewSheet: View {
    @ObservedObject var previewer: Previewer

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                switch previewer.content {
                case .live(let livePhoto):
                    LivePhotoPlayer(livePhoto: livePhoto)
                case .video(let player):
                    VideoPlayer(player: player)
                        .onAppear { player.play() }
                case .image(let image):
                    Image(uiImage: image).resizable().scaledToFit()
                case nil:
                    if previewer.message.isEmpty || previewer.message == "Downloading…" {
                        ProgressView().tint(.white)
                    }
                }
                if !previewer.message.isEmpty {
                    VStack {
                        Spacer()
                        Text(previewer.message)
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .padding()
                    }
                }
            }
            .navigationTitle(previewer.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") { previewer.isShown = false }
                }
            }
        }
        .onDisappear { previewer.close() }
    }
}

/// Shows a Live Photo, plays it once when it appears, and replays it when you press and hold.
struct LivePhotoPlayer: UIViewRepresentable {
    let livePhoto: PHLivePhoto

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        if view.livePhoto !== livePhoto {
            view.livePhoto = livePhoto
            view.startPlayback(with: .full)
        }
    }
}