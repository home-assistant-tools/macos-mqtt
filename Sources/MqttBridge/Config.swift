import Foundation

struct Camera: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String = ""
    var url: String = ""
}

struct Config: Codable {
    var host: String = "192.168.1.10"
    var port: Int = 1883
    var username: String = ""
    var password: String = ""
    var nodeId: String = "mac"
    var deviceName: String = "Mac"
    var discoveryPrefix: String = "homeassistant"

    var vlcPath: String = "/Applications/VLC.app/Contents/MacOS/VLC"
    var m1ddcPath: String = "/opt/homebrew/bin/m1ddc"
    var brightnessDisplays: [Int] = [1]

    var cameras: [Camera] = []

    static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("macos-mqtt", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var fileURL: URL { supportDir.appendingPathComponent("config.json") }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: fileURL),
              let cfg = try? JSONDecoder().decode(Config.self, from: data) else {
            var c = Config()
            // Default node id derived from host name for first run.
            c.nodeId = (Host.current().localizedName ?? "mac")
                .lowercased()
                .replacingOccurrences(of: " ", with: "_")
                .filter { $0.isLetter || $0.isNumber || $0 == "_" }
            c.deviceName = Host.current().localizedName ?? "Mac"
            return c
        }
        return cfg
    }

    func save() {
        guard let data = try? JSONEncoder().outputFormattingPretty().encode(self) else { return }
        try? data.write(to: Config.fileURL, options: .atomic)
        // Tighten permissions since the broker password is stored here.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Config.fileURL.path)
    }
}

private extension JSONEncoder {
    func outputFormattingPretty() -> JSONEncoder {
        outputFormatting = [.prettyPrinted, .sortedKeys]
        return self
    }
}
