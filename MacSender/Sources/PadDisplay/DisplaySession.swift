import Foundation
import CoreGraphics
import CoreMedia
import ScreenCaptureKit
import VirtualDisplayBridge

/// One iPad connection: creates a virtual monitor sized to the iPad, captures it,
/// encodes it, and streams it down the USB tunnel. Tearing it down removes the
/// virtual monitor, so windows jump back to your main screen like unplugging a cable.
final class DisplaySession: NSObject, SCStreamOutput, SCStreamDelegate {
    private let socket: Socket
    private let width: Int
    private let height: Int

    private var virtualDisplay: CGVirtualDisplay?   // must stay alive or the display vanishes
    private var stream: SCStream?
    private var encoder: H264Encoder?

    private let captureQueue = DispatchQueue(label: "paddisplay.capture", qos: .userInteractive)
    private let sendQueue = DispatchQueue(label: "paddisplay.send", qos: .userInteractive)

    private let lock = NSLock()
    private var pendingSends = 0
    private var isDisconnected = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var forceKeyFrame = true   // only touched on captureQueue

    init(socket: Socket, width: Int, height: Int) {
        self.socket = socket
        self.width = max(width, 640) & ~1
        self.height = max(height, 480) & ~1
        super.init()
    }

    func start() async throws {
        encoder = try H264Encoder(width: width, height: height) { [weak self] parameterSets, frame in
            self?.send(parameterSets: parameterSets, frame: frame)
        }
        watchForDisconnect()

        let displayID = try await MainActor.run { try self.createVirtualDisplay() }
        let scDisplay = try await findShareableDisplay(displayID)

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.queueDepth = 5

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func waitUntilDisconnected() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isDisconnected {
                lock.unlock()
                continuation.resume()
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func stop() async {
        markDisconnected()
        if let stream { try? await stream.stopCapture() }
        stream = nil
        encoder?.invalidate()
        encoder = nil
        socket.shutdown()
        await MainActor.run { self.virtualDisplay = nil }
    }

    // MARK: - Virtual display

    private func createVirtualDisplay() throws -> CGDirectDisplayID {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = "iPad (PadDisplay)"
        descriptor.maxPixelsWide = UInt32(width)
        descriptor.maxPixelsHigh = UInt32(height)
        // iPads are ~264 pixels per inch; this lets macOS pick a sensible scale.
        descriptor.sizeInMillimeters = CGSize(width: Double(width) / 264 * 25.4,
                                              height: Double(height) / 264 * 25.4)
        descriptor.productID = 0x1A2B
        descriptor.vendorID = 0x3C4D
        descriptor.serialNum = 0x0001

        guard let display = CGVirtualDisplay(descriptor: descriptor) else {
            throw PadError.virtualDisplayFailed
        }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = [CGVirtualDisplayMode(width: UInt32(width), height: UInt32(height), refreshRate: 60)]
        guard display.apply(settings) else { throw PadError.virtualDisplayFailed }

        virtualDisplay = display
        return display.displayID
    }

    private func findShareableDisplay(_ displayID: CGDirectDisplayID) async throws -> SCDisplay {
        // A brand-new display takes a moment to show up in ScreenCaptureKit.
        for _ in 0..<50 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let display = content.displays.first(where: { $0.displayID == displayID }) {
                return display
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw PadError.displayNotFound
    }

    // MARK: - Capture -> encode

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let infos = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = infos.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }   // idle frames (nothing changed) carry no image

        lock.lock()
        let backlog = pendingSends
        let gone = isDisconnected
        lock.unlock()
        if gone { return }

        if backlog > 3 {
            // USB link is behind: skip this frame and resync with a keyframe next time.
            forceKeyFrame = true
            return
        }
        encoder?.encode(pixelBuffer, forceKeyFrame: forceKeyFrame)
        forceKeyFrame = false
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("Screen capture stopped: \(error.localizedDescription)")
        markDisconnected()
    }

    // MARK: - Networking

    private func send(parameterSets: [Data]?, frame: Data) {
        var message = Data()
        if let parameterSets, !parameterSets.isEmpty {
            message.append(WireProtocol.message(.parameterSets, payload: WireProtocol.pack(parameterSets)))
        }
        message.append(WireProtocol.message(.frame, payload: frame))

        lock.lock()
        if isDisconnected { lock.unlock(); return }
        pendingSends += 1
        lock.unlock()

        sendQueue.async { [weak self] in
            guard let self else { return }
            do { try self.socket.writeAll(message) } catch { self.markDisconnected() }
            self.lock.lock()
            self.pendingSends -= 1
            self.lock.unlock()
        }
    }

    private func watchForDisconnect() {
        let socket = self.socket
        DispatchQueue.global(qos: .utility).async { [weak self] in
            socket.waitForClose()
            self?.markDisconnected()
        }
    }

    private func markDisconnected() {
        lock.lock()
        isDisconnected = true
        let continuation = waiter
        waiter = nil
        lock.unlock()
        continuation?.resume()
    }
}
