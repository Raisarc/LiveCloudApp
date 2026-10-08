import Photos
import SwiftUI

/// The iPhone's own library as a grid: filter by type, see what is already in pCloud,
/// select it all at once and delete it from the phone.
struct PhoneView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var library = PhoneLibrary()
    @State private var selecting = false
    @State private var confirmDelete = false
    @StateObject private var previewer = Previewer()

    private let columns = [GridItem(.adaptive(minimum: 90), spacing: 2)]

    var body: some View {
        NavigationStack {
            ScrollView {
                header
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(library.visibleAssets, id: \.localIdentifier) { asset in
                        SquareTile(selected: selecting ? library.selected.contains(asset.localIdentifier) : nil) {
                            AssetThumbnail(asset: asset)
                        } badges: {
                            backupBadge(library.state(of: asset))
                            if asset.mediaSubtypes.contains(.photoLive) {
                                Image(systemName: "livephoto")
                            }
                            if asset.mediaType == .video {
                                Text(duration(asset.duration))
                            }
                        }
                        .onTapGesture {
                            if selecting { library.toggle(asset) }
                        }
                        .onLongPressGesture(minimumDuration: 0.35) {
                            previewer.show(asset: asset)
                        }
                    }
                }
            }
            .overlay { if library.busy { ProgressView().controlSize(.large) } }
            .task { await library.start(client: model.client) }
            .refreshable { library.reload() }
            .safeAreaInset(edge: .bottom) {
                if selecting && !library.selected.isEmpty {
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Text("Delete \(library.selected.count) from iPhone").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(library.busy)
                    .padding()
                    .background(.bar)
                }
            }
            .confirmationDialog("Delete \(library.selected.count) item(s) from your iPhone?",
                                isPresented: $confirmDelete,
                                titleVisibility: .visible) {
                Button("Check with pCloud and delete", role: .destructive) {
                    guard let client = model.client else { return }
                    Task { await library.deleteSelected(client: client) }
                }
            } message: {
                Text("Each item is first compared byte-for-byte with pCloud. Only items with an exact copy there are deleted; anything else stays on your iPhone. Deleted items stay in Recently Deleted for 30 days.")
            }
            .sheet(isPresented: $previewer.isShown) {
                PreviewSheet(previewer: previewer)
            }
            .navigationTitle("iPhone")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(selecting ? "Done" : "Select") {
                        selecting.toggle()
                        library.selected = []
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Show", selection: $library.filter) {
                    ForEach(PhoneFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                Spacer()
                Text("\(library.visibleAssets.count) items")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Toggle("Only show what's already in pCloud", isOn: $library.onlyInCloud)
                .font(.subheadline)
            HStack {
                Button {
                    guard let client = model.client else { return }
                    Task { await library.checkBackups(client: client) }
                } label: {
                    Label("Re-check pCloud", systemImage: "arrow.clockwise.icloud")
                }
                .buttonStyle(.bordered)
                .disabled(library.busy)

                if selecting {
                    Button("Select all in pCloud (\(library.inCloudCount))") {
                        library.selectAllInCloud()
                    }
                    .buttonStyle(.bordered)
                    .disabled(library.busy || library.inCloudCount == 0)
                }
            }
            if !library.status.isEmpty {
                Text(library.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func backupBadge(_ state: BackupState?) -> some View {
        switch state {
        case .inCloud:
            Image(systemName: "checkmark.icloud.fill").foregroundStyle(.green)
        case .partial:
            Image(systemName: "exclamationmark.icloud.fill").foregroundStyle(.orange)
        case .missing:
            Image(systemName: "icloud.slash")
        case nil:
            EmptyView()
        }
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct AssetThumbnail: View {
    let asset: PHAsset
    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .onAppear(perform: load)
    }

    private func load() {
        guard image == nil else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        PHImageManager.default().requestImage(for: asset,
                                              targetSize: CGSize(width: 250, height: 250),
                                              contentMode: .aspectFill,
                                              options: options) { result, _ in
            if let result { image = result }
        }
    }
}