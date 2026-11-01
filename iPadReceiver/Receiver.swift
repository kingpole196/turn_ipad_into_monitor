import AVFoundation
import Combine
import CoreMedia
import Network
import UIKit

/// Listens on a local port. The Mac reaches it through the USB cable (via usbmuxd),
/// so no Wi-Fi and no shared Apple ID are needed. Decoding uses the iPad's
/// hardware H.264 decoder via AVSampleBufferDisplayLayer.
final class Receiver: ObservableObject {
    @Published private(set) var statusText = "Starting…"
    @Published private(set) var isStreaming = false

    let displayLayer = AVSampleBufferDisplayLayer()

    private let port: NWEndpoint.Port = 2345
    private let queue = DispatchQueue(label: "paddisplay.receiver", qos: .userInteractive)
    private var listener: NWListener?

    // Only touched on `queue`:
    private var connection: NWConnection?
    private var formatDescription: CMVideoFormatDescription?
    private var hasShownFrame = false
    private var screenPixelSize = (width: 0, height: 0)

    init() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
    }

    /// Call on the main thread.
    func start() {
        guard listener == nil else { return }

        // Native pixel size, reported in landscape.
        let native = UIScreen.main.nativeBounds.size
        let width = Int(max(native.width, native.height)) & ~1
        let height = Int(min(native.width, native.height)) & ~1
        queue.async { self.screenPixelSize = (width, height) }

        do {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback   // USB tunnel arrives on localhost
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    self?.updateStatus("Couldn't listen for the Mac: \(error)", streaming: false)
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            updateStatus("Waiting for your Mac…\nConnect the USB-C cable and run PadDisplay on the Mac.", streaming: false)
        } catch {
            updateStatus("Couldn't start: \(error)", streaming: false)
        }
    }

    /// Call on the main thread.
    func stop() {
        listener?.cancel()
        listener = nil
        queue.async {
            self.connection?.cancel()
            self.connection = nil
        }
    }

    // MARK: - Connection

    private func accept(_ newConnection: NWConnection) {   // runs on `queue`
        connection?.cancel()
        connection = newConnection
        formatDescription = nil
        hasShownFrame = false

        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            guard let self, let conn = newConnection else { return }
            switch state {
            case .ready:
                self.sendScreenSize(on: conn)
                self.updateStatus("Connected — waiting for the first frame…", streaming: false)
                self.readHeader(on: conn)
            case .failed, .cancelled:
                guard self.connection === conn else { return }
                self.connection = nil
                self.updateStatus("Mac disconnected.\nWaiting for it to reconnect…", streaming: false)
                DispatchQueue.main.async { self.displayLayer.flushAndRemoveImage() }
            default:
                break
            }
        }
        newConnection.start(queue: queue)
    }

    private func sendScreenSize(on conn: NWConnection) {
        var payload = Data()
        for value in [UInt32(screenPixelSize.width), UInt32(screenPixelSize.height)] {
            withUnsafeBytes(of: value.bigEndian) { payload.append(contentsOf: $0) }
        }
        conn.send(content: payload, completion: .contentProcessed { _ in })
    }

    // Message format: [1 byte type][4 byte big-endian length][payload]
    private func readHeader(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] data, _, _, error in
            guard let self else { return }
            guard error == nil, let data, data.count == 5 else { conn.cancel(); return }
            let b = [UInt8](data)
            let type = b[0]
            let length = Int(UInt32(b[1]) << 24 | UInt32(b[2]) << 16 | UInt32(b[3]) << 8 | UInt32(b[4]))
            if length == 0 {
                self.readHeader(on: conn)
            } else {
                self.readBody(on: conn, type: type, length: length)
            }
        }
    }

    private func readBody(on conn: NWConnection, type: UInt8, length: Int) {
        conn.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self else { return }
            guard error == nil, let data, data.count == length else { conn.cancel(); return }
            self.handle(type: type, payload: data)
            self.readHeader(on: conn)
        }
    }

    // MARK: - Decoding

    private func handle(type: UInt8, payload: Data) {
        switch type {
        case 1:  // SPS + PPS
            formatDescription = makeFormatDescription(from: payload)
        case 2:  // encoded frame
            guard let format = formatDescription,
                  let sample = makeSampleBuffer(payload, format: format) else { return }
            if !hasShownFrame {
                hasShownFrame = true
                updateStatus("", streaming: true)
            }
            DispatchQueue.main.async {
                if self.displayLayer.status == .failed { self.displayLayer.flush() }
                self.displayLayer.enqueue(sample)
            }
        default:
            break
        }
    }

    private func makeFormatDescription(from payload: Data) -> CMVideoFormatDescription? {
        var sets: [[UInt8]] = []
        let bytes = [UInt8](payload)
        var i = 0
        while i + 2 <= bytes.count {
            let length = Int(bytes[i]) << 8 | Int(bytes[i + 1])
            i += 2
            guard i + length <= bytes.count else { break }
            sets.append(Array(bytes[i..<(i + length)]))
            i += length
        }
        guard sets.count >= 2 else { return nil }

        let sps = sets[0], pps = sets[1]
        var format: CMFormatDescription?
        let status = sps.withUnsafeBufferPointer { spsPointer in
            pps.withUnsafeBufferPointer { ppsPointer in
                let pointers: [UnsafePointer<UInt8>] = [spsPointer.baseAddress!, ppsPointer.baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &format
                )
            }
        }
        return status == noErr ? format : nil
    }

    private func makeSampleBuffer(_ payload: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        let length = payload.count
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: length,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else { return nil }

        let copyStatus = payload.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: length)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        var sample: CMSampleBuffer?
        var sampleSize = length
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }

        // Show each frame as soon as it arrives (no timestamps / buffering).
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    private func updateStatus(_ text: String, streaming: Bool) {
        DispatchQueue.main.async {
            if !text.isEmpty { self.statusText = text }
            self.isStreaming = streaming
        }
    }
}
