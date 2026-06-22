import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: AppState

    @State private var host = ""
    @State private var port = "1883"
    @State private var username = ""
    @State private var password = ""
    @State private var nodeId = ""
    @State private var deviceName = ""
    @State private var discoveryPrefix = "homeassistant"
    @State private var vlcPath = ""
    @State private var m1ddcPath = ""
    @State private var brightnessDisplays = "1"
    @State private var cameras: [Camera] = []
    @State private var saved = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusBanner

                group("Broker MQTT") {
                    field("Địa chỉ", text: $host, placeholder: "192.168.1.10")
                    field("Cổng", text: $port, placeholder: "1883")
                    field("Username", text: $username)
                    secureField("Password", text: $password)
                }

                group("Thiết bị") {
                    field("Node ID", text: $nodeId, placeholder: "mac")
                    field("Tên hiển thị", text: $deviceName, placeholder: "Mac mini")
                    field("Discovery prefix", text: $discoveryPrefix)
                }

                group("Công cụ ngoài") {
                    field("Đường dẫn VLC", text: $vlcPath)
                    field("Đường dẫn m1ddc", text: $m1ddcPath)
                    field("Màn hình chỉnh sáng", text: $brightnessDisplays, placeholder: "để trống = tất cả")
                }

                cameraSection

                HStack {
                    Button("Lưu & kết nối lại") { saveAll() }
                        .keyboardShortcut(.defaultAction)
                    if saved {
                        Label("Đã lưu", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    Spacer()
                }
            }
            .padding(20)
            .frame(width: 480)
        }
        .onAppear(perform: loadFromConfig)
    }

    private var statusBanner: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(state.isConnected ? Color.green : Color.orange)
                .frame(width: 10, height: 10)
            Text(state.statusText).font(.callout)
        }
    }

    private var cameraSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Camera (RTSP)").font(.headline)
                Spacer()
                Button {
                    cameras.append(Camera(name: "Camera \(cameras.count + 1)", url: "rtsp://"))
                } label: { Image(systemName: "plus") }
            }
            ForEach($cameras) { $cam in
                HStack {
                    TextField("Tên", text: $cam.name).frame(width: 120)
                    TextField("rtsp://…", text: $cam.url)
                    Button(role: .destructive) {
                        cameras.removeAll { $0.id == cam.id }
                    } label: { Image(systemName: "trash") }
                }
            }
            if cameras.isEmpty {
                Text("Chưa có camera nào").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String = "") -> some View {
        HStack {
            Text(label).frame(width: 140, alignment: .leading).foregroundStyle(.secondary)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func secureField(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label).frame(width: 140, alignment: .leading).foregroundStyle(.secondary)
            SecureField("", text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func loadFromConfig() {
        let c = state.config
        host = c.host
        port = String(c.port)
        username = c.username
        password = c.password
        nodeId = c.nodeId
        deviceName = c.deviceName
        discoveryPrefix = c.discoveryPrefix
        vlcPath = c.vlcPath
        m1ddcPath = c.m1ddcPath
        brightnessDisplays = c.brightnessDisplays.map(String.init).joined(separator: ",")
        cameras = c.cameras
    }

    private func saveAll() {
        var c = state.config
        c.host = host.trimmingCharacters(in: .whitespaces)
        c.port = Int(port) ?? 1883
        c.username = username
        c.password = password
        c.nodeId = nodeId.trimmingCharacters(in: .whitespaces).isEmpty ? "mac" : nodeId.trimmingCharacters(in: .whitespaces)
        c.deviceName = deviceName
        c.discoveryPrefix = discoveryPrefix.isEmpty ? "homeassistant" : discoveryPrefix
        c.vlcPath = vlcPath
        c.m1ddcPath = m1ddcPath
        c.brightnessDisplays = brightnessDisplays
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        c.cameras = cameras.filter { !$0.name.isEmpty && !$0.url.isEmpty }
        state.save(c)
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
    }
}
