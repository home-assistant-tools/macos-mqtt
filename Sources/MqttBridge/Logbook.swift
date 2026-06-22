import Foundation
import Combine

/// In-memory + on-disk log of commands received and actions taken.
@MainActor
final class Logbook: ObservableObject {
    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let level: Level
        let text: String
    }
    enum Level: String { case info, cmd, action, warn, error }

    @Published private(set) var entries: [Entry] = []
    private let maxEntries = 2000

    private let fileURL = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/macos-mqtt.log")

    private lazy var formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private lazy var fileFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    init() {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    func add(_ text: String, level: Level = .info) {
        let e = Entry(date: Date(), level: level, text: text)
        entries.append(e)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        appendToFile(e)
    }

    func clear() { entries.removeAll() }

    func timeString(_ e: Entry) -> String { formatter.string(from: e.date) }

    private func appendToFile(_ e: Entry) {
        let line = "\(fileFormatter.string(from: e.date)) [\(e.level.rawValue.uppercased())] \(e.text)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: fileURL)
        }
    }
}
