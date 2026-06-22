import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppState.shared.start()
    }
    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.stop()
    }
}

extension AppState { static let shared = AppState() }

@main
struct MqttBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state)
        } label: {
            Image(systemName: state.isConnected
                  ? "antenna.radiowaves.left.and.right"
                  : "antenna.radiowaves.left.and.right.slash")
        }

        Window("MQTT Settings", id: "settings") {
            SettingsView(state: state)
        }
        .windowResizability(.contentSize)

        Window("Command Log", id: "log") {
            LogView(logbook: state.logbook)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(state.statusText)
        Divider()
        Button("MQTT Settings…") { open("settings") }
        Button("Command Log…") { open("log") }
        Button("Reconnect") { state.restart() }
        Divider()
        Button(LoginItem.isEnabled ? "✓ Open at Login" : "Open at Login") {
            LoginItem.toggle()
        }
        Divider()
        Text("macos-mqtt v\(state.version)")
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }

    private func open(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }
}
