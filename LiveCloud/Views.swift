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
