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
    @State private var nowplayingPath = ""
    @State private var brightnessDisplays = ""
    @State private var cameras: [Camera] = []
    @State private var saved = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusBanner

                group("MQTT Broker") {
                    field("Address", text: $host, placeholder: "192.168.1.10")
                    field("Port", text: $port, placeholder: "1883")
                    field("Username", text: $username)
                    secureField("Password", text: $password)
                }

                group("Device") {
                    field("Node ID", text: $nodeId, placeholder: "mac")
                    field("Display name", text: $deviceName, placeholder: "Mac mini")
                    field("Discovery prefix", text: $discoveryPrefix)
                }

                group("External tools") {
                    field("VLC path", text: $vlcPath)
                    field("m1ddc path", text: $m1ddcPath)
                    field("nowplaying-cli path", text: $nowplayingPath)
                    field("Brightness displays", text: $brightnessDisplays, placeholder: "blank = all")
                }

                cameraSection

                HStack {
                    Button("Save & reconnect") { saveAll() }
                        .keyboardShortcut(.defaultAction)
                    if saved {
                        Label("Saved", systemImage: "checkmark.circle.fill")
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
                Text("Cameras (RTSP)").font(.headline)
                Spacer()
                Button {
                    cameras.append(Camera(name: "Camera \(cameras.count + 1)", url: "rtsp://"))
                } label: { Image(systemName: "plus") }
            }
            ForEach($cameras) { $cam in
                HStack {
                    TextField("Name", text: $cam.name).frame(width: 120)
                    TextField("rtsp://…", text: $cam.url)
                    Button(role: .destructive) {
                        cameras.removeAll { $0.id == cam.id }
                    } label: { Image(systemName: "trash") }
                }
            }
            if cameras.isEmpty {
                Text("No cameras yet").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String = "") -> some View {
        HStack {
            Text(label).frame(width: 150, alignment: .leading).foregroundStyle(.secondary)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func secureField(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label).frame(width: 150, alignment: .leading).foregroundStyle(.secondary)
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
        nowplayingPath = c.nowplayingPath
        brightnessDisplays = c.brightnessDisplays.map(String.init).joined(separator: ",")
        cameras = c.cameras
    }

    private func saveAll() {
        var c = state.config
        c.host = host.trimmingCharacters(in: .whitespaces)
        c.port = Int(port) ?? 1883
        c.username = username
        c.password = password
        let trimmedNode = nodeId.trimmingCharacters(in: .whitespaces)
        c.nodeId = trimmedNode.isEmpty ? "mac" : trimmedNode
        c.deviceName = deviceName
        c.discoveryPrefix = discoveryPrefix.isEmpty ? "homeassistant" : discoveryPrefix
        c.vlcPath = vlcPath
        c.m1ddcPath = m1ddcPath
        c.nowplayingPath = nowplayingPath
        c.brightnessDisplays = brightnessDisplays
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        c.cameras = cameras.filter { !$0.name.isEmpty && !$0.url.isEmpty }
        state.save(c)
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
    }
}
