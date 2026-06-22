import Foundation
import Combine
import AppKit

@MainActor
final class AppState: ObservableObject {
    @Published var config: Config
    @Published var isConnected: Bool = false
    @Published var statusText: String = "Chưa kết nối"

    let logbook = Logbook()

    private var client: MQTTClient?
    private var bridge: Bridge?

    var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }

    init() {
        self.config = Config.load()
    }

    func start() {
        stop()
        let cfg = config
        guard !cfg.host.isEmpty else {
            statusText = "Thiếu địa chỉ broker — mở Cấu hình"
            logbook.add("Chưa cấu hình broker MQTT", level: .warn)
            return
        }
        let opts = MQTTClient.Options(
            host: cfg.host,
            port: UInt16(cfg.port),
            clientId: "macos-mqtt-\(cfg.nodeId)",
            username: cfg.username.isEmpty ? nil : cfg.username,
            password: cfg.password.isEmpty ? nil : cfg.password,
            keepAlive: 30,
            willTopic: "macosmqtt/\(cfg.nodeId)/availability",
            willPayload: "offline",
            willRetain: true,
            willQoS: 1
        )
        let c = MQTTClient(opts)
        let b = Bridge(config: cfg, client: c, version: version) { [weak self] msg, level in
            Task { @MainActor in self?.logbook.add(msg, level: level) }
        }
        c.onLog = { [weak self] msg in
            Task { @MainActor in self?.logbook.add(msg, level: .info) }
        }
        c.onState = { [weak self] st in
            Task { @MainActor in
                guard let self else { return }
                switch st {
                case .connected:
                    self.isConnected = true
                    self.statusText = "Đã kết nối \(cfg.host)"
                    b.onConnected()
                case .connecting:
                    self.isConnected = false
                    self.statusText = "Đang kết nối…"
                case .disconnected:
                    self.isConnected = false
                    self.statusText = "Mất kết nối"
                }
            }
        }
        c.onMessage = { [weak self] topic, payload in
            Task { @MainActor in self?.logbook.add("← \(topic) = \(payload)", level: .cmd) }
            b.handle(topic: topic, payload: payload)
        }
        self.client = c
        self.bridge = b
        logbook.add("Khởi động, kết nối tới \(cfg.host):\(cfg.port)…", level: .info)
        c.start()
    }

    func stop() {
        bridge?.stopTimers()
        client?.stop()
        client = nil
        bridge = nil
        isConnected = false
    }

    func restart() { start() }

    func save(_ newConfig: Config) {
        config = newConfig
        config.save()
        logbook.add("Đã lưu cấu hình, kết nối lại…", level: .info)
        restart()
    }
}
