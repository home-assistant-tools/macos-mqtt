# macos-mqtt — turn your Mac into a Home Assistant device over MQTT

A tiny macOS menu-bar app that turns your Mac into an MQTT device that
**Home Assistant auto-discovers** (MQTT Discovery). No Bun/Node/Python — just a
single native, Developer-ID-signed `.app`.

## Features

### Controls
| Entity | Type | Action |
|--------|------|--------|
| Volume | `number` | System output volume (0–100) |
| Mute | `switch` | Mute / unmute |
| Brightness | `number` | External display brightness over DDC (needs `m1ddc`) — controls **all** displays when none configured |
| Camera | `select` | Pick a configured RTSP camera |
| Cast camera | `button` | Open the selected camera **fullscreen** (via VLC) |
| Stop cast | `button` | Close the camera window |
| Cast URL | `text` | Cast any RTSP URL |
| Open app | `select` | Installed apps (auto-scanned) — **opens on selection** |
| Display | `switch` | Wake / sleep display — **state synced to real display power** |
| Notification | `text` | Show a banner on the Mac |
| Speak | `text` | Speak text through the Mac speakers (`say`) |
| Lock screen | `button` | Lock immediately |
| Run shortcut | `select` | macOS Shortcuts — **runs on selection** |
| Keep awake | `switch` | Prevent sleep (`caffeinate`) |
| Open URL | `text` | Open a web/deeplink |
| Sleep | `button` | Put the Mac to sleep |
| Play/Pause · Next · Previous | `button` | Media control (`nowplaying-cli`) |
| Audio output | `select` | Switch the default output device (CoreAudio) |

### Sensors
| Sensor | Type | Notes |
|--------|------|-------|
| CPU / RAM / Disk | `sensor` % | System usage |
| Local IP | `sensor` | LAN address |
| WiFi | `sensor` dBm | Signal strength (hidden on Ethernet) |
| Bluetooth | `binary_sensor` | On / off |
| Uptime | `sensor` | Time since boot |
| Disk free | `sensor` GB | Free space |
| Now playing | `sensor` | Current track (title — artist) |
| Audio app | `sensor` | App(s) currently producing audio |
| Battery / Charging | `sensor` % / `binary_sensor` | **Only on machines with a battery** |

Everything is grouped under **one device** in HA. A live **Command Log** window
records every command received from the server.

> Original goal: when someone **rings the doorbell**, HA presses *Cast camera* →
> the Mac shows the camera fullscreen, no manual app needed.

## Requirements

- macOS 13+
- **VLC** for RTSP casting — https://www.videolan.org (or set a different player path).
- **m1ddc** for external-display brightness: `brew install m1ddc` (optional).
- **nowplaying-cli** for media control / now-playing: `brew install nowplaying-cli` (optional).
- An MQTT broker (e.g. Mosquitto) that Home Assistant uses.

## Install

1. Download `MQTT-Bridge-x.y.z.zip` from [Releases](../../releases), unzip, drag
   **MQTT Bridge.app** into `/Applications`.
2. Open it — an icon appears in the **menu bar**.
3. Click it → **MQTT Settings…**, enter broker host/port/user/password, set a
   *Node ID*, add RTSP cameras → **Save & reconnect**.
4. In Home Assistant → **Settings → Devices** — the device appears automatically.
5. Click the menu icon → **Open at Login** to start it on boot.

Config is stored at `~/Library/Application Support/macos-mqtt/config.json` (chmod 600).
Log file: `~/Library/Logs/macos-mqtt.log`.

## Build from source

Needs Command Line Tools (`swift`), **no full Xcode required**.

```bash
# regenerate the icon (optional)
scripts/make_icon.sh

# build + sign (Developer ID)
SIGN_ID="Developer ID Application: YOUR NAME (TEAMID)" scripts/build.sh 2.0.0

# notarize for distribution (needs an app-specific password)
APPLE_ID="you@example.com" TEAM_ID="TEAMID" APP_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
    scripts/notarize.sh 2.0.0
```

Outputs `dist/MQTT Bridge.app` and `dist/MQTT-Bridge-2.0.0.zip`.

## Architecture

- **MQTTClient.swift** — hand-written MQTT 3.1.1 client over `Network.framework` (zero deps): CONNECT (user/pass + LWT), PUBLISH QoS 0/1 + retain, SUBSCRIBE, keepalive, auto-reconnect.
- **Bridge.swift** — builds HA MQTT-discovery payloads and routes commands ↔ actions.
- **SystemControls.swift** — volume/mute (osascript), brightness (m1ddc/DDC), cast (VLC), apps (`open`), shortcuts, media (`nowplaying-cli`), sensors, sleep/lock.
- **CoreAudioControls.swift** — list/switch the default output device and detect apps producing audio (native CoreAudio).
- **App / SettingsView / LogView** — SwiftUI menu-bar UI.

## License

MIT — see [LICENSE](LICENSE).
