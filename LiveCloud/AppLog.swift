import Foundation

/// On-screen log, since there is no Xcode debugger in this setup.
@MainActor
final class AppLog: ObservableObject {
    static let shared = AppLog()

    @Published private(set) var lines: [String] = []

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func add(_ message: String) {
        lines.append("\(formatter.string(from: Date()))  \(message)")
        if lines.count > 500 {
            lines.removeFirst(lines.count - 500)
        }
    }

    func clear() {
        lines.removeAll()
    }
}

/// Log from anywhere. Never pass passwords or tokens here.
func appLog(_ message: String) {
    Task { @MainActor in
        AppLog.shared.add(message)
    }
}
