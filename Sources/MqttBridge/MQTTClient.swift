import Foundation
import Network

/// Minimal, dependency-free MQTT 3.1.1 client over Network.framework.
/// Supports: CONNECT (username/password + LWT), PUBLISH (QoS 0/1, retain),
/// SUBSCRIBE (QoS 1), keepalive PING, and auto-reconnect.
final class MQTTClient {
    struct Options {
        var host: String
        var port: UInt16
        var clientId: String
        var username: String?
        var password: String?
        var keepAlive: UInt16 = 30
        var willTopic: String?
        var willPayload: String?
        var willRetain: Bool = true
        var willQoS: UInt8 = 1
    }

    enum State { case disconnected, connecting, connected }

    // Callbacks (invoked on the internal queue).
    var onState: ((State) -> Void)?
    var onMessage: ((_ topic: String, _ payload: String) -> Void)?
    var onLog: ((String) -> Void)?

    private(set) var state: State = .disconnected {
        didSet { onState?(state) }
    }

    private let opts: Options
    private let queue = DispatchQueue(label: "mqtt.client")
    private var conn: NWConnection?
    private var rxBuffer = Data()
    private var pingTimer: DispatchSourceTimer?
    private var reconnectTimer: DispatchSourceTimer?
    private var packetId: UInt16 = 0
    private var shouldRun = false
    private var reconnectDelay: TimeInterval = 2

    init(_ opts: Options) { self.opts = opts }

    // MARK: - Public

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.shouldRun = true
            self.connect()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.shouldRun = false
            self.cancelTimers()
            self.sendDisconnect()
            self.conn?.cancel()
            self.conn = nil
            self.state = .disconnected
        }
    }

    func publish(_ topic: String, _ payload: String, qos: UInt8 = 0, retain: Bool = false) {
        queue.async { [weak self] in
            self?.writePublish(topic: topic, payload: Data(payload.utf8), qos: qos, retain: retain)
        }
    }

    func subscribe(_ topics: [String], qos: UInt8 = 0) {
        queue.async { [weak self] in
            self?.writeSubscribe(topics: topics, qos: qos)
        }
    }

    // MARK: - Connection lifecycle

    private func connect() {
        guard shouldRun else { return }
        state = .connecting
        rxBuffer.removeAll(keepingCapacity: true)
        let host = NWEndpoint.Host(opts.host)
        guard let port = NWEndpoint.Port(rawValue: opts.port) else {
            onLog?("Cổng MQTT không hợp lệ: \(opts.port)")
            return
        }
        let c = NWConnection(host: host, port: port, using: .tcp)
        conn = c
        c.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                self.onLog?("TCP đã kết nối \(self.opts.host):\(self.opts.port), gửi CONNECT…")
                self.writeConnect()
                self.receiveLoop()
            case .failed(let err):
                self.onLog?("TCP lỗi: \(err.localizedDescription)")
                self.handleDisconnect()
            case .cancelled:
                break
            case .waiting(let err):
                self.onLog?("TCP chờ: \(err.localizedDescription)")
            default:
                break
            }
        }
        c.start(queue: queue)
    }

    private func handleDisconnect() {
        cancelTimers()
        conn?.cancel()
        conn = nil
        if state != .disconnected { state = .disconnected }
        guard shouldRun else { return }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        let delay = reconnectDelay
        t.schedule(deadline: .now() + delay)
        t.setEventHandler { [weak self] in
            guard let self, self.shouldRun else { return }
            self.onLog?("Thử kết nối lại…")
            self.connect()
        }
        reconnectTimer = t
        t.resume()
        reconnectDelay = min(reconnectDelay * 2, 30)
    }

    private func cancelTimers() {
        pingTimer?.cancel(); pingTimer = nil
        reconnectTimer?.cancel(); reconnectTimer = nil
    }

    private func startPing() {
        pingTimer?.cancel()
        guard opts.keepAlive > 0 else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval = TimeInterval(opts.keepAlive) * 0.8
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in
            self?.write(Data([0xC0, 0x00])) // PINGREQ
        }
        pingTimer = t
        t.resume()
    }

    // MARK: - Receiving

    private func receiveLoop() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.rxBuffer.append(data)
                self.parseBuffer()
            }
            if let error {
                self.onLog?("Lỗi đọc: \(error.localizedDescription)")
                self.handleDisconnect()
                return
            }
            if isComplete {
                self.onLog?("Server đóng kết nối")
                self.handleDisconnect()
                return
            }
            self.receiveLoop()
        }
    }

    /// Parse as many complete MQTT packets as are buffered.
    private func parseBuffer() {
        while true {
            guard rxBuffer.count >= 2 else { return }
            // Decode remaining length (varint, up to 4 bytes) starting at index 1.
            var multiplier = 1
            var value = 0
            var idx = 1
            var encodedBytes = 0
            while true {
                guard idx < rxBuffer.count else { return } // need more bytes
                let byte = rxBuffer[rxBuffer.startIndex + idx]
                value += Int(byte & 0x7F) * multiplier
                encodedBytes += 1
                idx += 1
                if byte & 0x80 == 0 { break }
                multiplier *= 128
                if encodedBytes > 4 { // malformed
                    onLog?("Gói MQTT lỗi (remaining length)")
                    handleDisconnect()
                    return
                }
            }
            let headerLen = 1 + encodedBytes
            let total = headerLen + value
            guard rxBuffer.count >= total else { return } // wait for full packet
            let header = rxBuffer[rxBuffer.startIndex]
            let body = rxBuffer.subdata(in: (rxBuffer.startIndex + headerLen)..<(rxBuffer.startIndex + total))
            rxBuffer.removeSubrange(rxBuffer.startIndex..<(rxBuffer.startIndex + total))
            dispatchPacket(header: header, body: body)
        }
    }

    private func dispatchPacket(header: UInt8, body: Data) {
        let type = header >> 4
        switch type {
        case 2: // CONNACK
            let code = body.count >= 2 ? body[body.startIndex + 1] : 0xFF
            if code == 0 {
                onLog?("CONNACK OK — đã kết nối MQTT")
                reconnectDelay = 2
                state = .connected
                startPing()
            } else {
                onLog?("CONNACK từ chối, mã=\(code)")
                handleDisconnect()
            }
        case 3: // PUBLISH
            handlePublish(header: header, body: body)
        case 9: // SUBACK
            break
        case 13: // PINGRESP
            break
        default:
            break
        }
    }

    private func handlePublish(header: UInt8, body: Data) {
        let qos = (header >> 1) & 0x03
        var cursor = body.startIndex
        guard body.count >= 2 else { return }
        let topicLen = Int(body[cursor]) << 8 | Int(body[cursor + 1])
        cursor += 2
        guard body.distance(from: body.startIndex, to: body.endIndex) >= 2 + topicLen else { return }
        let topicData = body.subdata(in: cursor..<(cursor + topicLen))
        cursor += topicLen
        var packetIdentifier: UInt16 = 0
        if qos > 0 {
            guard body.distance(from: cursor, to: body.endIndex) >= 2 else { return }
            packetIdentifier = UInt16(body[cursor]) << 8 | UInt16(body[cursor + 1])
            cursor += 2
        }
        let payloadData = body.subdata(in: cursor..<body.endIndex)
        let topic = String(decoding: topicData, as: UTF8.self)
        let payload = String(decoding: payloadData, as: UTF8.self)
        if qos == 1 {
            // PUBACK
            write(Data([0x40, 0x02, UInt8(packetIdentifier >> 8), UInt8(packetIdentifier & 0xFF)]))
        }
        onMessage?(topic, payload)
    }

    // MARK: - Writing packets

    private func nextPacketId() -> UInt16 {
        packetId &+= 1
        if packetId == 0 { packetId = 1 }
        return packetId
    }

    private func writeConnect() {
        var variable = Data()
        variable.append(encodeString("MQTT"))
        variable.append(0x04) // protocol level 3.1.1

        var flags: UInt8 = 0x02 // clean session
        if opts.username != nil { flags |= 0x80 }
        if opts.password != nil { flags |= 0x40 }
        if opts.willTopic != nil {
            flags |= 0x04
            flags |= (opts.willQoS & 0x03) << 3
            if opts.willRetain { flags |= 0x20 }
        }
        variable.append(flags)
        variable.append(UInt8(opts.keepAlive >> 8))
        variable.append(UInt8(opts.keepAlive & 0xFF))

        var payload = Data()
        payload.append(encodeString(opts.clientId))
        if let wt = opts.willTopic { payload.append(encodeString(wt)) }
        if let wp = opts.willPayload { payload.append(encodeString(wp)) }
        if let u = opts.username { payload.append(encodeString(u)) }
        if let p = opts.password { payload.append(encodeString(p)) }

        var packet = Data([0x10])
        packet.append(encodeRemainingLength(variable.count + payload.count))
        packet.append(variable)
        packet.append(payload)
        write(packet)
    }

    private func writePublish(topic: String, payload: Data, qos: UInt8, retain: Bool) {
        guard state == .connected else { return }
        var fixed: UInt8 = 0x30
        fixed |= (qos & 0x03) << 1
        if retain { fixed |= 0x01 }
        var variable = Data()
        variable.append(encodeString(topic))
        if qos > 0 {
            let pid = nextPacketId()
            variable.append(UInt8(pid >> 8))
            variable.append(UInt8(pid & 0xFF))
        }
        var packet = Data([fixed])
        packet.append(encodeRemainingLength(variable.count + payload.count))
        packet.append(variable)
        packet.append(payload)
        write(packet)
    }

    private func writeSubscribe(topics: [String], qos: UInt8) {
        guard state == .connected else { return }
        let pid = nextPacketId()
        var variable = Data([UInt8(pid >> 8), UInt8(pid & 0xFF)])
        for t in topics {
            variable.append(encodeString(t))
            variable.append(qos & 0x03)
        }
        var packet = Data([0x82])
        packet.append(encodeRemainingLength(variable.count))
        packet.append(variable)
        write(packet)
    }

    private func sendDisconnect() {
        guard state == .connected else { return }
        write(Data([0xE0, 0x00]))
    }

    private func write(_ data: Data) {
        conn?.send(content: data, completion: .contentProcessed { [weak self] err in
            if let err { self?.onLog?("Lỗi gửi: \(err.localizedDescription)") }
        })
    }

    // MARK: - Encoding helpers

    private func encodeString(_ s: String) -> Data {
        let bytes = Array(s.utf8)
        var d = Data([UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)])
        d.append(contentsOf: bytes)
        return d
    }

    private func encodeRemainingLength(_ length: Int) -> Data {
        var d = Data()
        var x = length
        repeat {
            var byte = UInt8(x % 128)
            x /= 128
            if x > 0 { byte |= 0x80 }
            d.append(byte)
        } while x > 0
        return d
    }
}
