# macos-mqtt — biến Mac thành thiết bị điều khiển qua Home Assistant (MQTT)

App menu-bar nhỏ gọn cho macOS, biến máy Mac thành một thiết bị MQTT mà
**Home Assistant tự động phát hiện** (MQTT Discovery). Không cần Bun/Node/Python —
chỉ một `.app` native đã ký Developer ID.

## Tính năng

App công bố các entity sau lên Home Assistant:

| Entity | Loại | Tác dụng |
|--------|------|----------|
| Âm lượng | `number` | Chỉnh âm lượng hệ thống (0–100) |
| Tắt tiếng | `switch` | Mute / unmute |
| Độ sáng | `number` | Chỉnh độ sáng màn hình ngoài qua DDC (cần `m1ddc`) |
| Camera | `select` | Chọn camera RTSP đã cấu hình |
| Cast camera | `button` | Mở camera đang chọn **fullscreen** (qua VLC) |
| Dừng cast | `button` | Tắt cửa sổ camera |
| Cast URL | `text` | Cast một URL RTSP bất kỳ |
| Mở ứng dụng | `select` | Danh sách app cài trên Mac (tự quét) — **chọn là mở ngay** |
| Màn hình | `switch` | Bật (đánh thức) / tắt màn hình |
| Thông báo | `text` | Hiện banner thông báo trên Mac |
| Đọc (TTS) | `text` | Đọc to văn bản qua loa Mac (`say`) |
| Khoá màn hình | `button` | Khoá màn hình ngay |
| Chạy Shortcut | `select` | Shortcut của macOS — **chọn là chạy ngay** (`shortcuts`) |
| Ngăn ngủ | `switch` | Giữ máy thức (`caffeinate`) |
| Mở URL | `text` | Mở web/deeplink trên Mac |
| Ngủ máy | `button` | Đưa Mac vào chế độ ngủ |

Độ sáng để trống danh sách màn hình → tự chỉnh **tất cả** màn hình DDC.

App cũng công bố các **sensor** theo dõi máy (cập nhật ~20s):

| Sensor | Loại | Ghi chú |
|--------|------|---------|
| CPU | `sensor` % | Mức dùng CPU |
| RAM | `sensor` % | Bộ nhớ đã dùng |
| Ổ đĩa | `sensor` % | Dung lượng đã dùng (volume Data) |
| IP local | `sensor` | Địa chỉ IP LAN |
| WiFi | `sensor` dBm | Cường độ sóng (ẩn nếu dùng Ethernet) |
| Bluetooth | `binary_sensor` | Bật/tắt |
| Uptime | `sensor` | Thời gian máy đã chạy |
| Đĩa trống | `sensor` GB | Dung lượng còn trống |
| Pin / Đang sạc | `sensor` % / `binary_sensor` | **Chỉ hiện nếu máy có pin** (laptop) |

Tất cả gom dưới **một thiết bị** trong HA. Có **màn hình Nhật ký lệnh** ghi lại mọi
lệnh nhận từ server theo thời gian thực.

> Ứng dụng gốc của dự án: khi có người **bấm chuông cửa**, HA bấm nút *Cast camera* →
> Mac tự bật camera fullscreen, không cần mở app Nhà thủ công.

## Yêu cầu

- macOS 13+
- **VLC** (cho tính năng cast RTSP): https://www.videolan.org — hoặc đổi đường dẫn player trong Cấu hình.
- **m1ddc** (cho độ sáng màn hình ngoài): `brew install m1ddc` (tuỳ chọn).
- Một broker MQTT (vd. Mosquitto) mà Home Assistant đang dùng.

## Cài đặt

1. Tải `MQTT-Bridge-x.y.z.zip` từ [Releases](../../releases), giải nén, kéo
   **MQTT Bridge.app** vào `/Applications`.
2. Mở app → biểu tượng xuất hiện trên **menu bar**.
3. Bấm icon → **Cấu hình MQTT…**, nhập broker host/port/user/password, đặt *Node ID*,
   thêm camera RTSP → **Lưu & kết nối lại**.
4. Vào Home Assistant → **Settings → Devices** → thiết bị mới sẽ tự xuất hiện.

Cấu hình lưu tại `~/Library/Application Support/macos-mqtt/config.json` (chmod 600).
Log file: `~/Library/Logs/macos-mqtt.log`.

## Tự chạy lúc đăng nhập

Bấm icon menu bar → **Mở khi đăng nhập** (dùng `SMAppService`). Hoặc thủ công:
System Settings → General → Login Items → thêm **MQTT Bridge.app**.

## Build từ source

Cần Command Line Tools (có `swift`), **không cần full Xcode**.

```bash
# build + ký (Developer ID)
SIGN_ID="Developer ID Application: TÊN BẠN (TEAMID)" scripts/build.sh 1.0.0

# notarize để phát hành (cần app-specific password)
APPLE_ID="you@example.com" TEAM_ID="TEAMID" APP_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
    scripts/notarize.sh 1.0.0
```

Kết quả ở `dist/MQTT Bridge.app` và `dist/MQTT-Bridge-1.0.0.zip`.

## Kiến trúc

- **MQTTClient.swift** — client MQTT 3.1.1 tự viết trên `Network.framework` (zero dependency): CONNECT (user/pass + LWT), PUBLISH QoS 0/1 + retain, SUBSCRIBE, keepalive, auto-reconnect.
- **Bridge.swift** — sinh payload HA MQTT Discovery + định tuyến lệnh ↔ hành động.
- **SystemControls.swift** — volume/mute (osascript), brightness (m1ddc/DDC), cast (VLC), app launcher (`open`), display sleep/wake.
- **App.swift / SettingsView / LogView** — UI SwiftUI menu-bar.

## License

MIT — xem [LICENSE](LICENSE).
