import PhotosUI
import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        Group {
            if model.client == nil {
                LoginView()
            } else {
                TabView {
                    UploadView()
                        .tabItem { Label("Upload", systemImage: "icloud.and.arrow.up") }
                    CloudView()
                        .tabItem { Label("pCloud", systemImage: "icloud.and.arrow.down") }
                    PhoneView()
                        .tabItem { Label("iPhone", systemImage: "iphone") }
                    LogView()
                        .tabItem { Label("Log", systemImage: "text.alignleft") }
                }
            }
        }
        .environmentObject(model)
    }
}

// MARK: - Login

struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @State private var email = ""
    @State private var password = ""
    @State private var host = PCloudClient.euHost

    var body: some View {
        NavigationStack {
            Form {
                Section("pCloud account") {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                    Picker("Data region", selection: $host) {
                        Text("Europe").tag(PCloudClient.euHost)
                        Text("United States").tag(PCloudClient.usHost)
                    }
                }
                Section {
                    Button {
                        Task { await model.login(email: email, password: password, preferredHost: host) }
                    } label: {
                        if model.busy { ProgressView() } else { Text("Log in") }
                    }
                    .disabled(email.isEmpty || password.isEmpty || model.busy)
                }
                if !model.status.isEmpty {
                    Section { Text(model.status).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("LiveCloud")
        }
    }
}

// MARK: - Upload

struct UploadView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: [PhotosPickerItem] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                PhotosPicker(selection: $selection,
                             maxSelectionCount: 50,
                             matching: .livePhotos,
                             photoLibrary: .shared()) {
                    Label("Choose Live Photos", systemImage: "livephoto")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    let chosen = selection
                    selection = []
                    Task { await model.upload(chosen) }
                } label: {
                    Text(selection.isEmpty ? "Upload" : "Upload \(selection.count) Live Photo(s)")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty || model.busy)

                if model.busy { ProgressView() }
                Text(model.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .padding()
            .navigationTitle("Upload")
        }
    }
}

// MARK: - pCloud folder

struct CloudView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var pending: CloudItem?

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 2)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if !model.status.isEmpty {
                    Text(model.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                }
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(model.items) { item in
                        SquareTile(selected: selecting ? selected.contains(item.id) : nil) {
                            CloudThumbnail(url: item.thumbFileID.flatMap { model.thumbnails[$0] },
                                           isVideo: item.photoName == nil)
                        } badges: {
                            if item.isLive {
                                Image(systemName: "livephoto")
                            } else if item.photoName == nil {
                                Image(systemName: "video.fill")
                            }
                        }
                        .onTapGesture {
                            if selecting {
                                if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
                            } else {
                                pending = item
                            }
                        }
                    }
                }
            }
            .overlay { if model.busy { ProgressView() } }
            .refreshable { await model.refresh() }
            .task { await model.refresh() }
            .confirmationDialog("Save to Photos?",
                                isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                                titleVisibility: .visible,
                                presenting: pending) { item in
                Button(item.isLive ? "Save as Live Photo" : "Save") {
                    Task { await model.saveToPhotos(item) }
                }
            } message: { item in
                Text(item.base)
            }
            .safeAreaInset(edge: .bottom) {
                if selecting && !selected.isEmpty {
                    Button {
                        let chosen = model.items.filter { selected.contains($0.id) }
                        selected = []
                        selecting = false
                        Task { await model.saveToPhotos(chosen) }
                    } label: {
                        Text("Save \(selected.count) to Photos").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy)
                    .padding()
                    .background(.bar)
                }
            }
            .navigationTitle("pCloud")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Log out") { model.logout() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(selecting ? "Done" : "Select") {
                        selecting.toggle()
                        selected = []
                    }
                }
            }
        }
    }
}

struct CloudThumbnail: View {
    let url: URL?
    let isVideo: Bool

    var body: some View {
        if let url {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.clear
            }
        } else {
            Image(systemName: isVideo ? "video" : "photo")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }
}

/// A square grid cell with an optional selection circle and small badges in the corner.
struct SquareTile<Content: View, Badges: View>: View {
    /// nil = not in selection mode.
    var selected: Bool?
    @ViewBuilder var content: Content
    @ViewBuilder var badges: Badges

    var body: some View {
        Rectangle()
            .fill(Color(.secondarySystemBackground))
            .aspectRatio(1, contentMode: .fit)
            .overlay { content }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 4) { badges }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 2)
                    .padding(5)
            }
            .overlay {
                if selected == true { Color.white.opacity(0.25) }
            }
            .overlay(alignment: .topTrailing) {
                if let selected {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, Color.accentColor)
                        .font(.title3)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                        .padding(5)
                }
            }
            .contentShape(Rectangle())
    }
}

// MARK: - Login

struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @State private var email = ""
    @State private var password = ""
    @State private var host = PCloudClient.euHost

    var body: some View {
        NavigationStack {
            Form {
                Section("pCloud account") {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                    Picker("Data region", selection: $host) {
                        Text("Europe").tag(PCloudClient.euHost)
                        Text("United States").tag(PCloudClient.usHost)
                    }
                }
                Section {
                    Button {
                        Task { await model.login(email: email, password: password, preferredHost: host) }
                    } label: {
                        if model.busy { ProgressView() } else { Text("Log in") }
                    }
                    .disabled(email.isEmpty || password.isEmpty || model.busy)
                }
                if !model.status.isEmpty {
                    Section { Text(model.status).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("LiveCloud")
        }
    }
}

// MARK: - Upload

struct UploadView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: [PhotosPickerItem] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                PhotosPicker(selection: $selection,
                             maxSelectionCount: 50,
                             matching: .livePhotos,
                             photoLibrary: .shared()) {
                    Label("Choose Live Photos", systemImage: "livephoto")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    let chosen = selection
                    selection = []
                    Task { await model.upload(chosen) }
                } label: {
                    Text(selection.isEmpty ? "Upload" : "Upload \(selection.count) Live Photo(s)")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty || model.busy)

                if model.busy { ProgressView() }
                Text(model.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .padding()
            .navigationTitle("Upload")
        }
    }
}

// MARK: - pCloud folder

struct CloudView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                if !model.status.isEmpty {
                    Text(model.status).font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(model.items) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.base).font(.subheadline)
                            Text(label(for: item)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Save") {
                            Task { await model.saveToPhotos(item) }
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.busy)
                    }
                }
            }
            .overlay { if model.busy { ProgressView() } }
            .refreshable { await model.refresh() }
            .task { await model.refresh() }
            .navigationTitle("pCloud")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Log out") { model.logout() }
                }
            }
        }
    }

    private func label(for item: CloudItem) -> String {
        if item.isLive { return "Live Photo" }
        return item.photoName != nil ? "Still only" : "Video only"
    }
}

// MARK: - Log

struct LogView: View {
    @ObservedObject private var log = AppLog.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(log.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Log")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Copy") { UIPasteboard.general.string = log.lines.joined(separator: "\n") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Clear") { log.clear() }
                }
            }
        }
    }
}
