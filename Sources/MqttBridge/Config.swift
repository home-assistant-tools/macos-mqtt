import Foundation

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
    var nowplayingPath: String = "/opt/homebrew/bin/nowplaying-cli"
    /// Empty = control all DDC displays automatically.
    var brightnessDisplays: [Int] = []

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

// Tolerant decoding: missing keys fall back to defaults so adding new fields
// in a future version never wipes an existing config.json.
extension Config {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var cfg = Config()
        cfg.host = try c.decodeIfPresent(String.self, forKey: .host) ?? cfg.host
        cfg.port = try c.decodeIfPresent(Int.self, forKey: .port) ?? cfg.port
        cfg.username = try c.decodeIfPresent(String.self, forKey: .username) ?? cfg.username
        cfg.password = try c.decodeIfPresent(String.self, forKey: .password) ?? cfg.password
        cfg.nodeId = try c.decodeIfPresent(String.self, forKey: .nodeId) ?? cfg.nodeId
        cfg.deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName) ?? cfg.deviceName
        cfg.discoveryPrefix = try c.decodeIfPresent(String.self, forKey: .discoveryPrefix) ?? cfg.discoveryPrefix
        cfg.vlcPath = try c.decodeIfPresent(String.self, forKey: .vlcPath) ?? cfg.vlcPath
        cfg.m1ddcPath = try c.decodeIfPresent(String.self, forKey: .m1ddcPath) ?? cfg.m1ddcPath
        cfg.nowplayingPath = try c.decodeIfPresent(String.self, forKey: .nowplayingPath) ?? cfg.nowplayingPath
        cfg.brightnessDisplays = try c.decodeIfPresent([Int].self, forKey: .brightnessDisplays) ?? cfg.brightnessDisplays
        self = cfg
    }
}

private extension JSONEncoder {
    func outputFormattingPretty() -> JSONEncoder {
        outputFormatting = [.prettyPrinted, .sortedKeys]
        return self
    }
}
