import Foundation

// PadDisplay (Mac side)
// Waits for the PadDisplay app on an iPad connected by USB, then turns the iPad
// into an extra monitor. Press Ctrl+C to quit; the virtual monitor disappears.

signal(SIGPIPE, SIG_IGN)
setvbuf(stdout, nil, _IOLBF, 0)

print("PadDisplay — waiting for your iPad over USB. Press Ctrl+C to quit.")

Task {
    var lastStatus = ""
    func status(_ text: String) {
        if text != lastStatus {
            print(text)
            lastStatus = text
        }
    }

    while true {
        do {
            let socket = try USBMux.connect(toDevicePort: WireProtocol.port)

            // Handshake: the iPad tells us its screen size in pixels (landscape).
            let size = try socket.readExactly(8)
            let width = Int(size.uint32BigEndian(at: 0))
            let height = Int(size.uint32BigEndian(at: 4))
            status("iPad connected — creating a \(width)×\(height) display…")

            let session = DisplaySession(socket: socket, width: width, height: height)
            do {
                try await session.start()
            } catch {
                await session.stop()
                throw error
            }
            status("Streaming! Arrange the iPad in System Settings → Displays.")

            await session.waitUntilDisconnected()
            await session.stop()
            status("iPad disconnected — waiting for it to come back…")
        } catch PadError.noDevice {
            status("No iPad on USB yet — plug it in and tap Trust if asked.")
        } catch PadError.appNotListening {
            status("iPad found — open the PadDisplay app on it.")
        } catch {
            status("Error: \(error)")
            if "\(error)".localizedCaseInsensitiveContains("declined") ||
               "\(error)".localizedCaseInsensitiveContains("permission") {
                print("→ Allow Terminal in System Settings → Privacy & Security → Screen & System Audio Recording, then reopen Terminal.")
            }
        }
        try? await Task.sleep(for: .seconds(1))
    }
}

dispatchMain()
