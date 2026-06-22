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
        let displays = config.brightnessDisplays.isEmpty ? allDisplayIndices() : config.brightnessDisplays
        for d in displays {
            runBg(config.m1ddcPath, ["display", String(d), "set", "luminance", String(clamped)])
        }
    }

    /// All DDC-capable displays as listed by `m1ddc display list` (1-based).
    /// Used when no specific displays are configured → control every monitor.
    func allDisplayIndices() -> [Int] {
        guard m1ddcAvailable else { return [] }
        let out = run(config.m1ddcPath, ["display", "list"])
        let count = out.split(separator: "\n").filter { $0.hasPrefix("[") }.count
        return count > 0 ? Array(1...count) : [1]
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

    // MARK: - Extra controls

    func notify(_ message: String, title: String = "Home Assistant") {
        let m = message.replacingOccurrences(of: "\"", with: "'")
        let t = title.replacingOccurrences(of: "\"", with: "'")
        _ = run("/usr/bin/osascript", ["-e", "display notification \"\(m)\" with title \"\(t)\""])
    }

    func say(_ text: String) {
        runBg("/usr/bin/say", [text])
    }

    func lockScreen() {
        runBg("/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession",
              ["-suspend"])
    }

    // MARK: - System metrics (sensors)

    func cpuPercent() -> Int? {
        let out = run("/usr/bin/top", ["-l", "2", "-n", "0"])
        let lines = out.split(separator: "\n").filter { $0.contains("CPU usage") }
        guard let line = lines.last,
              let r = line.range(of: #"[0-9.]+% idle"#, options: .regularExpression),
              let idle = Double(line[r].replacingOccurrences(of: "% idle", with: "")) else { return nil }
        return max(0, min(100, Int((100 - idle).rounded())))
    }

    func ramPercent() -> Int? {
        guard let total = Double(run("/usr/sbin/sysctl", ["-n", "hw.memsize"])), total > 0 else { return nil }
        let vm = run("/usr/bin/vm_stat", [])
        var pageSize = 16384.0
        if let r = vm.range(of: #"page size of (\d+) bytes"#, options: .regularExpression) {
            pageSize = Double(String(vm[r]).filter { $0.isNumber }) ?? 16384
        }
        func pages(_ key: String) -> Double {
            for line in vm.split(separator: "\n") where line.contains(key) {
                return Double(line.filter { $0.isNumber }) ?? 0
            }
            return 0
        }
        let used = (pages("Pages active") + pages("Pages wired down")
                    + pages("Pages occupied by compressor")) * pageSize
        return max(0, min(100, Int((used / total * 100).rounded())))
    }

    func diskPercent() -> Int? {
        let out = run("/bin/df", ["-k", "/System/Volumes/Data"])
        guard let line = out.split(separator: "\n").last else { return nil }
        for c in line.split(separator: " ", omittingEmptySubsequences: true) where c.hasSuffix("%") {
            return Int(c.dropLast())
        }
        return nil
    }

    func localIP() -> String? {
        let route = run("/sbin/route", ["-n", "get", "default"])
        var iface = ""
        for line in route.split(separator: "\n") where line.contains("interface:") {
            iface = line.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        }
        let candidates = iface.isEmpty ? ["en0", "en1"] : [iface]
        for c in candidates {
            let ip = run("/usr/sbin/ipconfig", ["getifaddr", c])
            if !ip.isEmpty { return ip }
        }
        return nil
    }

    func wifiRSSI() -> Int? {
        let out = run("/usr/sbin/system_profiler", ["SPAirPortDataType"])
        guard out.contains("Current Network Information") else { return nil }
        for line in out.split(separator: "\n") where line.contains("Signal / Noise") {
            if let r = line.range(of: #"-?\d+"#, options: .regularExpression) {
                return Int(line[r])
            }
        }
        return nil
    }

    func bluetoothOn() -> Bool? {
        let out = run("/usr/sbin/system_profiler", ["SPBluetoothDataType"])
        for line in out.split(separator: "\n") where line.contains("State:") || line.contains("Bluetooth Power") {
            return line.contains("On")
        }
        return nil
    }

    struct Battery { let percent: Int; let charging: Bool }

    func battery() -> Battery? {
        let out = run("/usr/bin/pmset", ["-g", "batt"])
        guard out.contains("InternalBattery") else { return nil }
        var pct = 0
        if let r = out.range(of: #"\d+%"#, options: .regularExpression) {
            pct = Int(out[r].dropLast()) ?? 0
        }
        return Battery(percent: pct, charging: !out.contains("discharging"))
    }

    func uptimeString() -> String? {
        // kern.boottime: "{ sec = 1718000000, usec = 0 } ..."
        let out = run("/usr/sbin/sysctl", ["-n", "kern.boottime"])
        guard let r = out.range(of: #"sec = (\d+)"#, options: .regularExpression),
              let boot = Int(String(out[r]).filter { $0.isNumber }) else { return nil }
        var secs = Int(Date().timeIntervalSince1970) - boot
        if secs < 0 { secs = 0 }
        let d = secs / 86400, h = (secs % 86400) / 3600, m = (secs % 3600) / 60
        if d > 0 { return "\(d)d \(h)h \(m)m" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    func diskFreeGB() -> Int? {
        let out = run("/bin/df", ["-k", "/System/Volumes/Data"])
        guard let line = out.split(separator: "\n").last else { return nil }
        let cols = line.split(separator: " ", omittingEmptySubsequences: true)
        // df -k columns: FS, blocks, used, available, capacity, ...
        guard cols.count >= 4, let availKB = Double(cols[3]) else { return nil }
        return Int((availKB / 1024 / 1024).rounded())
    }

    // MARK: - Shortcuts / URL / power

    func listShortcuts() -> [String] {
        let out = run("/usr/bin/shortcuts", ["list"])
        return out.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func runShortcut(_ name: String) {
        runBg("/usr/bin/shortcuts", ["run", name])
    }

    func openURL(_ url: String) {
        runBg("/usr/bin/open", [url])
    }

    func sleepNow() {
        runBg("/usr/bin/pmset", ["sleepnow"])
    }
}
