import Foundation

/// Ties the MQTT client to macOS controls and publishes Home Assistant
/// MQTT-discovery entities. All mutable state is confined to `queue`.
final class Bridge {
    private let cfg: Config
    private let controls: SystemControls
    private let client: MQTTClient
    private let log: (String, Logbook.Level) -> Void

    private let queue = DispatchQueue(label: "mqtt.bridge")
    private let sensorQueue = DispatchQueue(label: "mqtt.sensors")
    private var pollTimer: DispatchSourceTimer?
    private var appsTimer: DispatchSourceTimer?
    private var sensorTimer: DispatchSourceTimer?
    private var hasBattery = false
    private var publishedCount = 0

    // Entity state
    private var selectedCamera = ""
    private var selectedApp = ""
    private var selectedShortcut = ""
    private var selectedAudioOutput = ""
    private var brightness = 50
    private var lastVolume = -1
    private var lastMuted: Bool?
    private var lastDisplayOn: Bool?
    private var appList: [String] = []
    private var shortcutList: [String] = []
    private var audioDevices: [String] = []
    private var caffeinate: Process?

    private let appVersion: String

    private var base: String { "macosmqtt/\(cfg.nodeId)" }
    private var availabilityTopic: String { "\(base)/availability" }

    init(config: Config, client: MQTTClient, version: String,
         log: @escaping (String, Logbook.Level) -> Void) {
        self.cfg = config
        self.controls = SystemControls(config: config)
        self.client = client
        self.appVersion = version
        self.log = log
        self.selectedCamera = config.cameras.first?.name ?? ""
    }

    // MARK: - Lifecycle

    func onConnected() {
        queue.async { [weak self] in
            guard let self else { return }
            self.appList = self.controls.listApps()
            self.shortcutList = self.controls.listShortcuts()
            self.audioDevices = AudioControls.outputDevices()
            if self.selectedApp.isEmpty { self.selectedApp = self.appList.first ?? "" }
            if self.selectedShortcut.isEmpty { self.selectedShortcut = self.shortcutList.first ?? "" }
            self.selectedAudioOutput = AudioControls.currentOutput() ?? self.audioDevices.first ?? ""
            self.brightness = 50
            self.hasBattery = self.controls.battery() != nil

            self.client.publish(self.availabilityTopic, "online", qos: 1, retain: true)
            self.publishDiscovery()
            self.clearDeprecatedDiscovery()
            self.subscribeCommands()
            self.publishAllStates()
            self.startTimers()
            self.log("Published \(self.publishedCount) discovery entities, subscribed to commands", .info)
        }
    }

    func handle(topic: String, payload: String) {
        queue.async { [weak self] in self?.route(topic: topic, payload: payload) }
    }

    // MARK: - Command routing

    private func route(topic: String, payload: String) {
        let t = topic.hasPrefix(base + "/") ? String(topic.dropFirst(base.count + 1)) : topic
        switch t {
        case "volume/set":
            let v = Int(payload) ?? 0
            controls.setVolume(v); lastVolume = v
            client.publish("\(base)/volume", String(v), retain: true)
            log("volume → \(v)", .action)
        case "mute/set":
            let m = (payload == "ON")
            controls.setMuted(m); lastMuted = m
            client.publish("\(base)/mute", m ? "ON" : "OFF", retain: true)
            log("mute → \(m ? "ON" : "OFF")", .action)
        case "brightness/set":
            let v = Int(payload) ?? brightness
            controls.setBrightness(v); brightness = v
            client.publish("\(base)/brightness", String(v), retain: true)
            log(controls.m1ddcAvailable ? "brightness → \(v)" : "brightness \(v) (m1ddc not installed)",
                controls.m1ddcAvailable ? .action : .warn)
        case "camera/set":
            selectedCamera = payload
            client.publish("\(base)/camera", payload, retain: true)
            log("camera → \(payload)", .action)
        case "cast/press":
            castSelected()
        case "stop_cast/press":
            controls.stopCast(); log("stop cast", .action)
        case "cast_url/set":
            if !payload.isEmpty {
                controls.cast(url: payload)
                log(controls.vlcAvailable ? "cast url → \(payload)" : "cast url (VLC not installed)",
                    controls.vlcAvailable ? .action : .warn)
            }
            client.publish("\(base)/cast_url", "", retain: true)
        case "app/set":
            selectedApp = payload
            controls.openApp(payload)
            client.publish("\(base)/app", payload, retain: true)
            log("open app → \(payload)", .action)
        case "display/set":
            if payload == "ON" { controls.wakeDisplay() } else { controls.sleepDisplay() }
            log("display → \(payload)", .action)
        case "notify/set":
            if !payload.isEmpty { controls.notify(payload); log("notify: \(payload)", .action) }
            client.publish("\(base)/notify", "", retain: true)
        case "say/set":
            if !payload.isEmpty { controls.say(payload); log("speak: \(payload)", .action) }
            client.publish("\(base)/say", "", retain: true)
        case "lock/press":
            controls.lockScreen(); log("lock screen", .action)
        case "shortcut/set":
            selectedShortcut = payload
            controls.runShortcut(payload)
            client.publish("\(base)/shortcut", payload, retain: true)
            log("run shortcut → \(payload)", .action)
        case "open_url/set":
            if !payload.isEmpty { controls.openURL(payload); log("open url: \(payload)", .action) }
            client.publish("\(base)/open_url", "", retain: true)
        case "sleep/press":
            controls.sleepNow(); log("sleep", .action)
        case "caffeinate/set":
            setCaffeinate(payload == "ON")
        case "media_playpause/press":
            controls.mediaPlayPause(); log("media play/pause", .action)
        case "media_next/press":
            controls.mediaNext(); log("media next", .action)
        case "media_previous/press":
            controls.mediaPrevious(); log("media previous", .action)
        case "audio_output/set":
            selectedAudioOutput = payload
            AudioControls.setOutput(payload)
            client.publish("\(base)/audio_output", payload, retain: true)
            log("audio output → \(payload)", .action)
        default:
            log("unknown command: \(topic)", .warn)
        }
    }

    private func castSelected() {
        let cam = cfg.cameras.first { $0.name == selectedCamera } ?? cfg.cameras.first
        guard let cam else { log("cast: no camera configured", .warn); return }
        controls.cast(url: cam.url)
        log(controls.vlcAvailable ? "cast \(cam.name)" : "cast \(cam.name) (VLC not installed)",
            controls.vlcAvailable ? .action : .warn)
    }

    private func setCaffeinate(_ on: Bool) {
        if on {
            if caffeinate?.isRunning == true { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            p.arguments = ["-dimsu"]
            try? p.run()
            caffeinate = p
            log("keep awake: ON", .action)
        } else {
            caffeinate?.terminate(); caffeinate = nil
            log("keep awake: OFF", .action)
        }
        client.publish("\(base)/caffeinate", on ? "ON" : "OFF", retain: true)
    }

    // MARK: - State

    private func publishAllStates() {
        let v = controls.getVolume(); lastVolume = v
        let m = controls.getMuted(); lastMuted = m
        let displayOn = !controls.displayAsleep(); lastDisplayOn = displayOn
        client.publish("\(base)/volume", String(v), retain: true)
        client.publish("\(base)/mute", m ? "ON" : "OFF", retain: true)
        client.publish("\(base)/brightness", String(brightness), retain: true)
        client.publish("\(base)/camera", selectedCamera, retain: true)
        client.publish("\(base)/app", selectedApp, retain: true)
        client.publish("\(base)/shortcut", selectedShortcut, retain: true)
        client.publish("\(base)/audio_output", selectedAudioOutput, retain: true)
        client.publish("\(base)/display", displayOn ? "ON" : "OFF", retain: true)
        client.publish("\(base)/caffeinate", caffeinate?.isRunning == true ? "ON" : "OFF", retain: true)
        // Text inputs start empty (avoid "unknown").
        for obj in ["cast_url", "notify", "say", "open_url"] {
            client.publish("\(base)/\(obj)", "", retain: true)
        }
    }

    private func startTimers() {
        pollTimer?.cancel()
        let pt = DispatchSource.makeTimerSource(queue: queue)
        pt.schedule(deadline: .now() + 5, repeating: 5)
        pt.setEventHandler { [weak self] in self?.pollFast() }
        pollTimer = pt; pt.resume()

        appsTimer?.cancel()
        let at = DispatchSource.makeTimerSource(queue: queue)
        at.schedule(deadline: .now() + 300, repeating: 300)
        at.setEventHandler { [weak self] in self?.refreshLists() }
        appsTimer = at; at.resume()

        sensorTimer?.cancel()
        let st = DispatchSource.makeTimerSource(queue: sensorQueue)
        st.schedule(deadline: .now() + 1, repeating: 20)
        st.setEventHandler { [weak self] in self?.publishSensors() }
        sensorTimer = st; st.resume()
    }

    func stopTimers() {
        queue.async { [weak self] in
            self?.pollTimer?.cancel(); self?.pollTimer = nil
            self?.appsTimer?.cancel(); self?.appsTimer = nil
            self?.caffeinate?.terminate(); self?.caffeinate = nil
        }
        sensorQueue.async { [weak self] in
            self?.sensorTimer?.cancel(); self?.sensorTimer = nil
        }
    }

    /// Volume, mute and display power synced to HA (reflect manual changes).
    private func pollFast() {
        let v = controls.getVolume()
        let m = controls.getMuted()
        let displayOn = !controls.displayAsleep()
        if v != lastVolume { lastVolume = v; client.publish("\(base)/volume", String(v), retain: true) }
        if m != lastMuted { lastMuted = m; client.publish("\(base)/mute", m ? "ON" : "OFF", retain: true) }
        if displayOn != lastDisplayOn {
            lastDisplayOn = displayOn
            client.publish("\(base)/display", displayOn ? "ON" : "OFF", retain: true)
        }
    }

    private func refreshLists() {
        let apps = controls.listApps()
        if apps != appList { appList = apps; publishAppSelectDiscovery() }
        let shortcuts = controls.listShortcuts()
        if shortcuts != shortcutList { shortcutList = shortcuts; publishShortcutSelectDiscovery() }
        let devs = AudioControls.outputDevices()
        if devs != audioDevices { audioDevices = devs; publishAudioOutputDiscovery() }
    }

    private func publishSensors() {
        if let v = controls.cpuPercent() { client.publish("\(base)/cpu", String(v), retain: true) }
        if let v = controls.ramPercent() { client.publish("\(base)/ram", String(v), retain: true) }
        if let v = controls.diskPercent() { client.publish("\(base)/disk", String(v), retain: true) }
        if let v = controls.localIP() { client.publish("\(base)/ip", v, retain: true) }
        if let v = controls.wifiRSSI() { client.publish("\(base)/wifi", String(v), retain: true) }
        if let v = controls.bluetoothOn() { client.publish("\(base)/bluetooth", v ? "ON" : "OFF", retain: true) }
        if let v = controls.uptimeString() { client.publish("\(base)/uptime", v, retain: true) }
        if let v = controls.diskFreeGB() { client.publish("\(base)/disk_free", String(v), retain: true) }
        client.publish("\(base)/now_playing", controls.nowPlaying(), retain: true)
        client.publish("\(base)/audio_app", controls.audioApps(), retain: true)
        if hasBattery, let b = controls.battery() {
            client.publish("\(base)/battery", String(b.percent), retain: true)
            client.publish("\(base)/charging", b.charging ? "ON" : "OFF", retain: true)
        }
    }

    // MARK: - Discovery

    private func subscribeCommands() {
        client.subscribe([
            "\(base)/volume/set", "\(base)/mute/set", "\(base)/brightness/set",
            "\(base)/camera/set", "\(base)/cast/press", "\(base)/stop_cast/press",
            "\(base)/cast_url/set", "\(base)/app/set", "\(base)/display/set",
            "\(base)/notify/set", "\(base)/say/set", "\(base)/lock/press",
            "\(base)/shortcut/set", "\(base)/open_url/set", "\(base)/sleep/press",
            "\(base)/caffeinate/set", "\(base)/media_playpause/press",
            "\(base)/media_next/press", "\(base)/media_previous/press",
            "\(base)/audio_output/set",
        ], qos: 1)
    }

    private var device: [String: Any] {
        [
            "identifiers": ["macosmqtt_\(cfg.nodeId)"],
            "name": cfg.deviceName,
            "manufacturer": "home-assistant-tools",
            "model": "macos-mqtt",
            "sw_version": appVersion,
        ]
    }

    private func publish(discovery component: String, _ obj: String, _ extra: [String: Any]) {
        var payload: [String: Any] = [
            "unique_id": "\(cfg.nodeId)_\(obj)",
            "object_id": "\(cfg.nodeId)_\(obj)",
            "has_entity_name": true,
            "availability_topic": availabilityTopic,
            "payload_available": "online",
            "payload_not_available": "offline",
            "device": device,
        ]
        extra.forEach { payload[$0] = $1 }
        let topic = "\(cfg.discoveryPrefix)/\(component)/\(cfg.nodeId)/\(obj)/config"
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        client.publish(topic, json, qos: 1, retain: true)
        publishedCount += 1
    }

    private func publishDiscovery() {
        publishedCount = 0
        publish(discovery: "number", "volume", [
            "name": "Volume", "icon": "mdi:volume-high",
            "command_topic": "\(base)/volume/set", "state_topic": "\(base)/volume",
            "min": 0, "max": 100, "step": 1, "mode": "slider", "unit_of_measurement": "%",
        ])
        publish(discovery: "switch", "mute", [
            "name": "Mute", "icon": "mdi:volume-mute",
            "command_topic": "\(base)/mute/set", "state_topic": "\(base)/mute",
            "payload_on": "ON", "payload_off": "OFF",
        ])
        publish(discovery: "number", "brightness", [
            "name": "Brightness", "icon": "mdi:brightness-6",
            "command_topic": "\(base)/brightness/set", "state_topic": "\(base)/brightness",
            "min": 0, "max": 100, "step": 1, "mode": "slider", "unit_of_measurement": "%",
        ])
        publish(discovery: "select", "camera", [
            "name": "Camera", "icon": "mdi:cctv",
            "command_topic": "\(base)/camera/set", "state_topic": "\(base)/camera",
            "options": cfg.cameras.isEmpty ? ["—"] : cfg.cameras.map { $0.name },
        ])
        publish(discovery: "button", "cast", [
            "name": "Cast camera", "icon": "mdi:cast", "command_topic": "\(base)/cast/press",
        ])
        publish(discovery: "button", "stop_cast", [
            "name": "Stop cast", "icon": "mdi:cast-off", "command_topic": "\(base)/stop_cast/press",
        ])
        publish(discovery: "text", "cast_url", [
            "name": "Cast URL", "icon": "mdi:link-variant",
            "command_topic": "\(base)/cast_url/set", "state_topic": "\(base)/cast_url",
            "min": 0, "max": 255, "mode": "text",
        ])
        publishAppSelectDiscovery()
        publish(discovery: "switch", "display", [
            "name": "Display", "icon": "mdi:monitor",
            "command_topic": "\(base)/display/set", "state_topic": "\(base)/display",
            "payload_on": "ON", "payload_off": "OFF",
        ])
        publish(discovery: "text", "notify", [
            "name": "Notification", "icon": "mdi:bell",
            "command_topic": "\(base)/notify/set", "state_topic": "\(base)/notify",
            "min": 0, "max": 255, "mode": "text",
        ])
        publish(discovery: "text", "say", [
            "name": "Speak", "icon": "mdi:bullhorn",
            "command_topic": "\(base)/say/set", "state_topic": "\(base)/say",
            "min": 0, "max": 255, "mode": "text",
        ])
        publish(discovery: "button", "lock", [
            "name": "Lock screen", "icon": "mdi:lock", "command_topic": "\(base)/lock/press",
        ])
        publishShortcutSelectDiscovery()
        publish(discovery: "switch", "caffeinate", [
            "name": "Keep awake", "icon": "mdi:coffee",
            "command_topic": "\(base)/caffeinate/set", "state_topic": "\(base)/caffeinate",
            "payload_on": "ON", "payload_off": "OFF",
        ])
        publish(discovery: "text", "open_url", [
            "name": "Open URL", "icon": "mdi:web",
            "command_topic": "\(base)/open_url/set", "state_topic": "\(base)/open_url",
            "min": 0, "max": 255, "mode": "text",
        ])
        publish(discovery: "button", "sleep", [
            "name": "Sleep", "icon": "mdi:power-sleep", "command_topic": "\(base)/sleep/press",
        ])

        // Media controls
        publish(discovery: "button", "media_playpause", [
            "name": "Play/Pause", "icon": "mdi:play-pause",
            "command_topic": "\(base)/media_playpause/press",
        ])
        publish(discovery: "button", "media_next", [
            "name": "Next", "icon": "mdi:skip-next", "command_topic": "\(base)/media_next/press",
        ])
        publish(discovery: "button", "media_previous", [
            "name": "Previous", "icon": "mdi:skip-previous",
            "command_topic": "\(base)/media_previous/press",
        ])
        publishAudioOutputDiscovery()

        // Sensors
        publish(discovery: "sensor", "cpu", [
            "name": "CPU", "icon": "mdi:cpu-64-bit", "state_topic": "\(base)/cpu",
            "unit_of_measurement": "%", "state_class": "measurement",
        ])
        publish(discovery: "sensor", "ram", [
            "name": "RAM", "icon": "mdi:memory", "state_topic": "\(base)/ram",
            "unit_of_measurement": "%", "state_class": "measurement",
        ])
        publish(discovery: "sensor", "disk", [
            "name": "Disk", "icon": "mdi:harddisk", "state_topic": "\(base)/disk",
            "unit_of_measurement": "%", "state_class": "measurement",
        ])
        publish(discovery: "sensor", "ip", [
            "name": "Local IP", "icon": "mdi:ip-network", "state_topic": "\(base)/ip",
        ])
        publish(discovery: "sensor", "wifi", [
            "name": "WiFi", "icon": "mdi:wifi", "state_topic": "\(base)/wifi",
            "unit_of_measurement": "dBm", "device_class": "signal_strength",
            "state_class": "measurement",
        ])
        publish(discovery: "binary_sensor", "bluetooth", [
            "name": "Bluetooth", "icon": "mdi:bluetooth", "state_topic": "\(base)/bluetooth",
            "payload_on": "ON", "payload_off": "OFF",
        ])
        publish(discovery: "sensor", "uptime", [
            "name": "Uptime", "icon": "mdi:timer-outline", "state_topic": "\(base)/uptime",
        ])
        publish(discovery: "sensor", "disk_free", [
            "name": "Disk free", "icon": "mdi:harddisk", "state_topic": "\(base)/disk_free",
            "unit_of_measurement": "GB", "state_class": "measurement",
        ])
        publish(discovery: "sensor", "now_playing", [
            "name": "Now playing", "icon": "mdi:music", "state_topic": "\(base)/now_playing",
        ])
        publish(discovery: "sensor", "audio_app", [
            "name": "Audio app", "icon": "mdi:application-cog", "state_topic": "\(base)/audio_app",
        ])
        if hasBattery {
            publish(discovery: "sensor", "battery", [
                "name": "Battery", "state_topic": "\(base)/battery",
                "unit_of_measurement": "%", "device_class": "battery",
                "state_class": "measurement",
            ])
            publish(discovery: "binary_sensor", "charging", [
                "name": "Charging", "state_topic": "\(base)/charging",
                "device_class": "battery_charging", "payload_on": "ON", "payload_off": "OFF",
            ])
        }
    }

    private func publishAppSelectDiscovery() {
        publish(discovery: "select", "app", [
            "name": "Open app", "icon": "mdi:apps",
            "command_topic": "\(base)/app/set", "state_topic": "\(base)/app",
            "options": appList.isEmpty ? ["—"] : appList,
        ])
    }

    private func publishShortcutSelectDiscovery() {
        publish(discovery: "select", "shortcut", [
            "name": "Run shortcut", "icon": "mdi:apple",
            "command_topic": "\(base)/shortcut/set", "state_topic": "\(base)/shortcut",
            "options": shortcutList.isEmpty ? ["—"] : shortcutList,
        ])
    }

    private func publishAudioOutputDiscovery() {
        publish(discovery: "select", "audio_output", [
            "name": "Audio output", "icon": "mdi:speaker",
            "command_topic": "\(base)/audio_output/set", "state_topic": "\(base)/audio_output",
            "options": audioDevices.isEmpty ? ["—"] : audioDevices,
        ])
    }

    /// Remove entities that existed in older versions (publish empty retained config).
    private func clearDeprecatedDiscovery() {
        for (component, obj) in [("button", "open_app"), ("button", "run_shortcut")] {
            client.publish("\(cfg.discoveryPrefix)/\(component)/\(cfg.nodeId)/\(obj)/config",
                           "", qos: 1, retain: true)
        }
    }
}
