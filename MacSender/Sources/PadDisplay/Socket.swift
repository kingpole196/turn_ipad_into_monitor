import Foundation

enum PadError: Error, CustomStringConvertible {
    case usbmuxUnavailable
    case noDevice
    case appNotListening
    case disconnected
    case protocolError(String)
    case virtualDisplayFailed
    case displayNotFound
    case encoderFailed(OSStatus)

    var description: String {
        switch self {
        case .usbmuxUnavailable: return "Couldn't talk to macOS's USB device service (usbmuxd)."
        case .noDevice: return "No iPad found on USB."
        case .appNotListening: return "iPad found, but the PadDisplay app isn't open on it."
        case .disconnected: return "Connection closed."
        case .protocolError(let detail): return "Protocol error: \(detail)"
        case .virtualDisplayFailed: return "macOS refused to create the virtual display."
        case .displayNotFound: return "The virtual display never appeared (check Screen Recording permission)."
        case .encoderFailed(let status): return "Video encoder error \(status)."
        }
    }
}

/// A thin blocking wrapper around a file-descriptor socket.
final class Socket {
    let fd: Int32

    init(fd: Int32) {
        self.fd = fd
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { Darwin.close(fd) }

    func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, base + offset, raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { throw PadError.disconnected }
                offset += n
            }
        }
    }

    func readExactly(_ count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!
            var offset = 0
            while offset < count {
                let n = Darwin.read(fd, base + offset, count - offset)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { throw PadError.disconnected }
                offset += n
            }
        }
        return data
    }

    /// Blocks until the other side closes the connection (the iPad never sends
    /// anything after its handshake, so any read result <= 0 means it's gone).
    func waitForClose() {
        var byte: UInt8 = 0
        while true {
            let n = Darwin.read(fd, &byte, 1)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return }
        }
    }

    /// Wakes up any thread blocked in read/write on this socket.
    func shutdown() { _ = Darwin.shutdown(fd, SHUT_RDWR) }
}

extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
    mutating func appendBigEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
    mutating func appendBigEndian(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
    func uint32LittleEndian(at offset: Int) -> UInt32 {
        let b = [UInt8](self)
        return UInt32(b[offset]) | UInt32(b[offset + 1]) << 8 | UInt32(b[offset + 2]) << 16 | UInt32(b[offset + 3]) << 24
    }
    func uint32BigEndian(at offset: Int) -> UInt32 {
        let b = [UInt8](self)
        return UInt32(b[offset]) << 24 | UInt32(b[offset + 1]) << 16 | UInt32(b[offset + 2]) << 8 | UInt32(b[offset + 3])
    }
}

/// Mac -> iPad message format: [1 byte type][4 byte big-endian length][payload]
enum MessageType: UInt8 {
    case parameterSets = 1   // H.264 SPS + PPS, each as [2 byte length][bytes]
    case frame = 2           // one encoded H.264 frame (AVCC, 4-byte NAL lengths)
}

enum WireProtocol {
    static let port: UInt16 = 2345

    static func message(_ type: MessageType, payload: Data) -> Data {
        var data = Data([type.rawValue])
        data.appendBigEndian(UInt32(payload.count))
        data.append(payload)
        return data
    }

    static func pack(_ parameterSets: [Data]) -> Data {
        var data = Data()
        for set in parameterSets {
            data.appendBigEndian(UInt16(set.count))
            data.append(set)
        }
        return data
    }
}
