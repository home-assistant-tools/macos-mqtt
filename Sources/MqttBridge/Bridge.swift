import Foundation

/// Ties the MQTT client to macOS controls and publishes Home Assistant
/// MQTT-discovery entities. All mutable state is confined to `queue`.
final class Bridge {
    private let cfg: Config
    private let controls: SystemControls
    private let client: MQTTClient
    private let log: (String, Logbook.Level) -> Void

    private let queue = DispatchQueue(label: "mqtt.bridge")
    private var pollTimer: DispatchSourceTimer?
    private var appsTimer: DispatchSourceTimer?

    // Entity state
    private var selectedCamera: String = ""
    private var selectedApp: String = ""
    private var brightness: Int = 50
    private var lastVolume: Int = -1
    private var lastMuted: Bool?
    private var appList: [String] = []

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

    // Called by AppState when MQTT becomes connected.
    func onConnected() {
        queue.async { [weak self] in
            guard let self else { return }
            self.appList = self.controls.listApps()
            if self.selectedApp.isEmpty { self.selectedApp = self.appList.first ?? "" }
            self.brightness = self.initialBrightness()

            self.client.publish(self.availabilityTopic, "online", qos: 1, retain: true)
            self.publishDiscovery()
            self.subscribeCommands()
            self.publishAllStates()
            self.startTimers()
            self.log("Đã publish \(self.entityCount) entity discovery + subscribe lệnh", .info)
        }
    }

    func handle(topic: String, payload: String) {
        queue.async { [weak self] in
            self?.route(topic: topic, payload: payload)
        }
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
            log(controls.m1ddcAvailable ? "brightness → \(v)" : "brightness \(v) (m1ddc chưa cài)",
                controls.m1ddcAvailable ? .action : .warn)
        case "camera/set":
            selectedCamera = payload
            client.publish("\(base)/camera", payload, retain: true)
            log("camera chọn → \(payload)", .action)
        case "cast/press":
            castSelected()
        case "stop_cast/press":
            controls.stopCast()
            log("dừng cast", .action)
        case "cast_url/set":
            if !payload.isEmpty {
                controls.cast(url: payload)
                client.publish("\(base)/cast_url", payload, retain: true)
                log(controls.vlcAvailable ? "cast url → \(payload)" : "cast url (VLC chưa cài)",
                    controls.vlcAvailable ? .action : .warn)
            }
        case "app/set":
            selectedApp = payload
            client.publish("\(base)/app", payload, retain: true)
            log("app chọn → \(payload)", .action)
        case "open_app/press":
            if !selectedApp.isEmpty {
                controls.openApp(selectedApp)
                log("mở app → \(selectedApp)", .action)
            }
        case "display/set":
            if payload == "ON" { controls.wakeDisplay() } else { controls.sleepDisplay() }
            client.publish("\(base)/display", payload, retain: true)
            log("display → \(payload)", .action)
        default:
            log("lệnh không rõ: \(topic)", .warn)
        }
    }

    private func castSelected() {
        let cam = cfg.cameras.first { $0.name == selectedCamera } ?? cfg.cameras.first
        guard let cam else { log("cast: chưa cấu hình camera", .warn); return }
        controls.cast(url: cam.url)
        log(controls.vlcAvailable ? "cast \(cam.name)" : "cast \(cam.name) (VLC chưa cài)",
            controls.vlcAvailable ? .action : .warn)
    }

    // MARK: - State publishing

    private func publishAllStates() {
        let v = controls.getVolume(); lastVolume = v
        let m = controls.getMuted(); lastMuted = m
        client.publish("\(base)/volume", String(v), retain: true)
        client.publish("\(base)/mute", m ? "ON" : "OFF", retain: true)
        client.publish("\(base)/brightness", String(brightness), retain: true)
        client.publish("\(base)/camera", selectedCamera, retain: true)
        client.publish("\(base)/app", selectedApp, retain: true)
        client.publish("\(base)/display", "ON", retain: true)
    }

    private func startTimers() {
        // Sync volume/mute back to HA every 10s (reflect manual changes).
        pollTimer?.cancel()
        let pt = DispatchSource.makeTimerSource(queue: queue)
        pt.schedule(deadline: .now() + 10, repeating: 10)
        pt.setEventHandler { [weak self] in self?.pollVolume() }
        pollTimer = pt; pt.resume()

        // Rescan installed apps every 5 minutes; republish if changed.
        appsTimer?.cancel()
        let at = DispatchSource.makeTimerSource(queue: queue)
        at.schedule(deadline: .now() + 300, repeating: 300)
        at.setEventHandler { [weak self] in self?.refreshApps() }
        appsTimer = at; at.resume()
    }

    func stopTimers() {
        queue.async { [weak self] in
            self?.pollTimer?.cancel(); self?.pollTimer = nil
            self?.appsTimer?.cancel(); self?.appsTimer = nil
        }
    }

    private func pollVolume() {
        let v = controls.getVolume()
        let m = controls.getMuted()
        if v != lastVolume { lastVolume = v; client.publish("\(base)/volume", String(v), retain: true) }
        if m != lastMuted { lastMuted = m; client.publish("\(base)/mute", m ? "ON" : "OFF", retain: true) }
    }

    private func refreshApps() {
        let fresh = controls.listApps()
        if fresh != appList {
            appList = fresh
            publishAppSelectDiscovery()
            log("Cập nhật danh sách app (\(fresh.count))", .info)
        }
    }

    private func initialBrightness() -> Int {
        guard controls.m1ddcAvailable else { return 50 }
        // DDC reads are unreliable; sanitize and fall back to 50.
        return 50
    }

    // MARK: - Discovery

    private let entityCount = 10

    private func subscribeCommands() {
        client.subscribe([
            "\(base)/volume/set", "\(base)/mute/set", "\(base)/brightness/set",
            "\(base)/camera/set", "\(base)/cast/press", "\(base)/stop_cast/press",
            "\(base)/cast_url/set", "\(base)/app/set", "\(base)/open_app/press",
            "\(base)/display/set",
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
    }

    private func publishDiscovery() {
        publish(discovery: "number", "volume", [
            "name": "Âm lượng", "icon": "mdi:volume-high",
            "command_topic": "\(base)/volume/set", "state_topic": "\(base)/volume",
            "min": 0, "max": 100, "step": 1, "mode": "slider", "unit_of_measurement": "%",
        ])
        publish(discovery: "switch", "mute", [
            "name": "Tắt tiếng", "icon": "mdi:volume-mute",
            "command_topic": "\(base)/mute/set", "state_topic": "\(base)/mute",
            "payload_on": "ON", "payload_off": "OFF",
        ])
        publish(discovery: "number", "brightness", [
            "name": "Độ sáng", "icon": "mdi:brightness-6",
            "command_topic": "\(base)/brightness/set", "state_topic": "\(base)/brightness",
            "min": 0, "max": 100, "step": 1, "mode": "slider", "unit_of_measurement": "%",
        ])
        publish(discovery: "select", "camera", [
            "name": "Camera", "icon": "mdi:cctv",
            "command_topic": "\(base)/camera/set", "state_topic": "\(base)/camera",
            "options": cfg.cameras.isEmpty ? ["—"] : cfg.cameras.map { $0.name },
        ])
        publish(discovery: "button", "cast", [
            "name": "Cast camera", "icon": "mdi:cast",
            "command_topic": "\(base)/cast/press",
        ])
        publish(discovery: "button", "stop_cast", [
            "name": "Dừng cast", "icon": "mdi:cast-off",
            "command_topic": "\(base)/stop_cast/press",
        ])
        publish(discovery: "text", "cast_url", [
            "name": "Cast URL", "icon": "mdi:link-variant",
            "command_topic": "\(base)/cast_url/set", "state_topic": "\(base)/cast_url",
            "min": 0, "max": 255, "mode": "text",
        ])
        publishAppSelectDiscovery()
        publish(discovery: "button", "open_app", [
            "name": "Mở ứng dụng", "icon": "mdi:application",
            "command_topic": "\(base)/open_app/press",
        ])
        publish(discovery: "switch", "display", [
            "name": "Màn hình", "icon": "mdi:monitor",
            "command_topic": "\(base)/display/set", "state_topic": "\(base)/display",
            "payload_on": "ON", "payload_off": "OFF",
        ])
    }

    private func publishAppSelectDiscovery() {
        publish(discovery: "select", "app", [
            "name": "Ứng dụng", "icon": "mdi:apps",
            "command_topic": "\(base)/app/set", "state_topic": "\(base)/app",
            "options": appList.isEmpty ? ["—"] : appList,
        ])
    }
}
