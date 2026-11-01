# PadDisplay — use your iPad as a USB-C monitor for your Mac (free)

i created this using ai coz i didnt want to pay for apps.
you only need a usb-c cable(dont need a hdmi cable)
i used my ipad as a seccond display of my mac mini, with different apple ids


**How it works:** the Mac program creates a virtual monitor sized to your iPad, records it, compresses it with the M4's hardware video encoder, and sends it through the USB-C cable. The iPad app decodes it with the iPad's hardware decoder and shows it full-screen.

The two devices can use **different Apple IDs**. No Wi-Fi, capture card, or subscription is needed.

```
MacSender/      Mac command-line program (Swift Package)
iPadReceiver/   3 Swift files for the iPad app (you put them in an Xcode project)
```

---

## What you need

- **Xcode** (free, from the Mac App Store). Open it once after installing so it finishes setup.
- An iPad on **iPadOS 17 or newer**, plus your USB-C cable.
- A free Apple Account added to Xcode. This is the one on your Mac; the iPad's Apple ID doesn't matter.

---

## Part A — Build the Mac side

1. Open **Terminal** and go to the folder:
   ```
   cd ~/Downloads/PadDisplay/MacSender
   ```
   Adjust the path if you unzipped it somewhere else.
2. Build it:
   ```
   swift build -c release
   ```
3. Do a test run:
   ```
   .build/release/PadDisplay
   ```
   It should say it's waiting for your iPad. Press **Ctrl+C** for now.

---

## Part B — Install the iPad app

1. In Xcode, choose **File → New → Project → iOS → App**.
   - Product Name: `PadDisplay`
   - Interface: **SwiftUI**. Language: **Swift**.
2. In the left sidebar, **delete** the generated `ContentView.swift` and `PadDisplayApp.swift` (choose *Move to Trash*).
3. **Drag** the three files from `iPadReceiver/` into the same group in the sidebar, and tick *Copy items if needed*.
4. Click the blue project icon, then the **PadDisplay** target, then **General**:
   - **Minimum Deployments:** iOS 17.0
   - **Supported Destinations:** remove iPhone, Mac, and Vision, leaving iPad.
   - **Device Orientation:** tick only **Landscape Left** and **Landscape Right**.
   - Tick **Requires full screen**.
5. Open **Signing & Capabilities**:
   - Team → **Add an Account…**, sign in, then pick "(Your Name) (Personal Team)".
   - Change **Bundle Identifier** to something unique, e.g. `com.nads.paddisplay`.
6. Plug the iPad into the Mac and tap **Trust** on the iPad.
7. On the iPad, go to **Settings → Privacy & Security → Developer Mode** and turn it **On**. The iPad will restart. This option only appears after the iPad has been connected to Xcode once.
8. In Xcode's top bar, choose your **iPad** as the run destination and press **⌘R**.
9. The first time, the iPad may block the app. Go to **Settings → General → VPN & Device Management**, tap your developer profile, then tap **Trust**.

> **Free accounts:** apps signed with a free Personal Team expire after **7 days**. When it stops opening, plug in and press ⌘R in Xcode again; it takes about 30 seconds.

---

## Using it

1. Connect the iPad with the USB-C cable and **open PadDisplay on the iPad**. It shows "Waiting for your Mac…".
2. On the Mac, run:
   ```
   ~/Downloads/PadDisplay/MacSender/.build/release/PadDisplay
   ```
3. **First run only:** macOS asks for Screen Recording permission for Terminal. Allow it in **System Settings → Privacy & Security → Screen & System Audio Recording**, **quit and reopen Terminal**, and run the command again.
4. The iPad now acts as a second monitor. In **System Settings → Displays** you can:
   - Drag it to match where the iPad physically sits.
   - Choose a larger "looks like" size if text is too small.
   - Switch between extending and mirroring.
5. **Ctrl+C** in Terminal stops it. The virtual monitor disappears and windows move back to your main screen.

**Tip:** to start it with one word, add an alias:
```
echo "alias paddisplay='~/Downloads/PadDisplay/MacSender/.build/release/PadDisplay'" >> ~/.zshrc
```
Then open a new Terminal and type `paddisplay`.

---

## Limitations

- **Display only, no touch.** Use your Mac's mouse and keyboard. The pointer moves onto the iPad like any monitor.
- **Not a login screen.** It only runs after you log into the Mac. If the iPad is your *only* screen, you still need a monitor or remote login after a restart.
- **Uses a private macOS API** (`CGVirtualDisplay`) to create the virtual monitor, the same one apps like DeskPad and BetterDisplay use. A future macOS update could change it.
- **Keep the iPad app open in the foreground.** If you switch away, the picture stops; open it again and it reconnects.
- If an iPhone is also plugged in by USB, unplug it, because the Mac connects to the first device it finds.

## Troubleshooting

| Message / symptom | Fix |
|---|---|
| "No iPad on USB yet" | Re-plug the cable and tap Trust. Use a data-capable USB-C cable, not a charge-only one. |
| "iPad found — open the PadDisplay app" | Open the app on the iPad and keep it in front. |
| Error mentioning permission / declined | Grant Screen Recording to Terminal (see step 3 above) and reopen Terminal. |
| "The virtual display never appeared" | Same as above, then run again. |
| Picture is laggy | Lower the bitrate in `H264Encoder.swift` (`AverageBitRate`) or use a USB 3 cable. |
