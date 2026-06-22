import Foundation
import AppKit

/// Wraps macOS system actions: volume, mute, brightness (DDC via m1ddc),
/// app launching, RTSP casting (VLC) and display sleep/wake.
struct SystemControls {
    var config: Config

    // MARK: - Process helpers

    @discardableResult
    private func run(_ launchPath: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runBg(_ launchPath: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    private func osa(_ script: String) -> String {
        run("/usr/bin/osascript", ["-e", script])
    }

    // MARK: - Volume

    func getVolume() -> Int {
        Int(osa("output volume of (get volume settings)")) ?? 0
    }

    func setVolume(_ v: Int) {
        let clamped = max(0, min(100, v))
        _ = osa("set volume output volume \(clamped)")
    }

    func getMuted() -> Bool {
        osa("output muted of (get volume settings)") == "true"
    }

    func setMuted(_ muted: Bool) {
        _ = osa("set volume output muted \(muted ? "true" : "false")")
    }

    // MARK: - Brightness (external displays via DDC)

    var m1ddcAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: config.m1ddcPath)
    }

    func setBrightness(_ v: Int) {
        let clamped = max(0, min(100, v))
        guard m1ddcAvailable else { return }
        for d in config.brightnessDisplays {
            runBg(config.m1ddcPath, ["display", String(d), "set", "luminance", String(clamped)])
        }
    }

    // MARK: - Apps

    func listApps() -> [String] {
        let dirs = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications",
        ]
        var names = Set<String>()
        let fm = FileManager.default
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".app") {
                names.insert(String(item.dropLast(4)))
            }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func openApp(_ name: String) {
        runBg("/usr/bin/open", ["-a", name])
    }

    // MARK: - Casting (RTSP fullscreen via VLC)

    var vlcAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: config.vlcPath)
    }

    func cast(url: String) {
        stopCast()
        // Wake displays so the feed is visible immediately.
        runBg("/usr/bin/caffeinate", ["-u", "-t", "2"])
        guard vlcAvailable else { return }
        let vlc = config.vlcPath
        let args = ["--fullscreen", "--rtsp-tcp", "--no-video-title-show",
                    "--video-on-top", "--network-caching=200", url]
        // Small delay so the previous VLC fully exits before relaunching.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            self.runBg(vlc, args)
        }
    }

    func stopCast() {
        runBg("/usr/bin/pkill", ["-x", "VLC"])
    }

    // MARK: - Display power

    func wakeDisplay() {
        runBg("/usr/bin/caffeinate", ["-u", "-t", "1"])
    }

    func sleepDisplay() {
        runBg("/usr/bin/pmset", ["displaysleepnow"])
    }
}
