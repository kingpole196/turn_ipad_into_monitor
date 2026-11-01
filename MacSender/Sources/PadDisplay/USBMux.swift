import Foundation

/// Talks to usbmuxd, the macOS service that lets a Mac open TCP connections
/// to ports on an iPhone/iPad over the USB cable (no Wi-Fi, no Apple ID).
enum USBMux {
    private static let socketPath = "/var/run/usbmuxd"

    /// Opens a tunnel to `port` on the first iPad/iPhone connected by USB.
    static func connect(toDevicePort port: UInt16) throws -> Socket {
        let deviceID = try firstUSBDeviceID()
        let socket = try openSocket()
        try send([
            "MessageType": "Connect",
            "DeviceID": deviceID,
            "PortNumber": Int(port.bigEndian),   // usbmuxd wants network byte order
        ], on: socket, tag: 2)
        let reply = try receive(on: socket)
        guard let result = reply["Number"] as? Int else {
            throw PadError.protocolError("unexpected usbmuxd reply")
        }
        guard result == 0 else { throw PadError.appNotListening }
        return socket   // from here on, this socket is a raw pipe to the iPad app
    }

    private static func firstUSBDeviceID() throws -> Int {
        let socket = try openSocket()
        try send(["MessageType": "ListDevices"], on: socket, tag: 1)
        let reply = try receive(on: socket)
        guard let devices = reply["DeviceList"] as? [[String: Any]] else {
            throw PadError.protocolError("no DeviceList in usbmuxd reply")
        }
        for device in devices {
            let properties = device["Properties"] as? [String: Any]
            if properties?["ConnectionType"] as? String == "USB",
               let id = device["DeviceID"] as? Int {
                return id
            }
        }
        throw PadError.noDevice
    }

    private static func openSocket() throws -> Socket {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PadError.usbmuxUnavailable }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (i, byte) in pathBytes.enumerated() where i < buffer.count - 1 {
                buffer[i] = byte
            }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, length)
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw PadError.usbmuxUnavailable
        }
        return Socket(fd: fd)
    }

    /// usbmuxd packet: 16-byte little-endian header + XML plist body.
    private static func send(_ message: [String: Any], on socket: Socket, tag: UInt32) throws {
        var body = message
        body["ClientVersionString"] = "PadDisplay"
        body["ProgName"] = "PadDisplay"
        let payload = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)

        var packet = Data()
        packet.appendLittleEndian(UInt32(16 + payload.count)) // total length
        packet.appendLittleEndian(1)                          // protocol version
        packet.appendLittleEndian(8)                          // message type: plist
        packet.appendLittleEndian(tag)
        packet.append(payload)
        try socket.writeAll(packet)
    }

    private static func receive(on socket: Socket) throws -> [String: Any] {
        let header = try socket.readExactly(16)
        let bodyLength = Int(header.uint32LittleEndian(at: 0)) - 16
        guard bodyLength > 0 else { throw PadError.protocolError("empty usbmuxd reply") }
        let body = try socket.readExactly(bodyLength)
        guard let dict = try PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any] else {
            throw PadError.protocolError("bad usbmuxd plist")
        }
        return dict
    }
}
