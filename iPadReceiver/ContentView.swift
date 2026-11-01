import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var receiver = Receiver()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black
            VideoLayerView(videoLayer: receiver.displayLayer)
            if !receiver.isStreaming {
                VStack(spacing: 16) {
                    Image(systemName: "display")
                        .font(.system(size: 56))
                    Text(receiver.statusText)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white)
                .padding()
            }
        }
        .ignoresSafeArea()
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true   // keep the screen awake
            receiver.start()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: receiver.start()
            case .background: receiver.stop()
            default: break
            }
        }
    }
}

/// Hosts the AVSampleBufferDisplayLayer that shows the decoded Mac screen.
struct VideoLayerView: UIViewRepresentable {
    let videoLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> LayerHostView {
        LayerHostView(videoLayer: videoLayer)
    }

    func updateUIView(_ uiView: LayerHostView, context: Context) {}
}

final class LayerHostView: UIView {
    private let videoLayer: AVSampleBufferDisplayLayer

    init(videoLayer: AVSampleBufferDisplayLayer) {
        self.videoLayer = videoLayer
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(videoLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
    }
}
