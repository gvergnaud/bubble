// Owner: app/UI track. The camera bubble (design.md §6.3): a circle, center-cropped, mirrored,
// 2 pt white ring, soft shadow; a dark circle with a small spinner before the first frame.
// This view IS what ends up in the video (the screen capture records the bubble window).
import AVFoundation
import AppKit
import SwiftUI

/// What fills the circle.
public enum BubbleContent {
    /// Before the camera's first frame.
    case waiting
    /// A still image (snapshots, BUBBLE_FAKE mode).
    case image(CGImage)
    /// The camera. `live` false = frames stopped (restarting, switching): the preview stays in the
    /// view tree, hidden under the spinner. Its AVCaptureVideoPreviewLayer is created once and never
    /// re-attached: re-adding a preview layer while the session starts killed the session (-11800,
    /// the black bubble on the first real launch).
    case camera(AVCaptureSession, live: Bool)
}

public struct BubbleView: View {
    var content: BubbleContent
    var diameter: CGFloat
    var mirrored: Bool
    var dimmed: Bool

    /// Room around the circle for the shadow. The bubble window is the circle's frame grown by this.
    public static let shadowPadding: CGFloat = 18

    /// The camera is on but gives no picture: "Camera unavailable" in place of the face.
    var unavailable: Bool

    public init(content: BubbleContent, diameter: CGFloat, mirrored: Bool = true, dimmed: Bool = false, unavailable: Bool = false) {
        self.content = content; self.diameter = diameter; self.mirrored = mirrored; self.dimmed = dimmed
        self.unavailable = unavailable
    }

    public var body: some View {
        ZStack {
            Circle().fill(Color(white: 0.11))
            fill
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
            if unavailable {
                // In the video: a glyph only, no error text for viewers to read (the words go to
                // the user in a toast).
                Circle().fill(Color(white: 0.11))
                Image(systemName: "video.slash.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: diameter * 0.3, height: diameter * 0.3)
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            if dimmed {
                // Paused: an opaque bubble with a scrim and a pause glyph (a see-through face read as a glitch).
                Circle().fill(Color.black.opacity(0.45))
                Image(systemName: "pause.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: diameter * 0.28, height: diameter * 0.28)
                    .foregroundStyle(.white)
            }
            Circle()
                .strokeBorder(Color.white, lineWidth: 2)
        }
        .frame(width: diameter, height: diameter)
        .compositingGroup()
        .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
        .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
        .padding(Self.shadowPadding)
    }

    @ViewBuilder private var fill: some View {
        switch content {
        case .waiting:
            BubbleSpinner(size: max(16, diameter * 0.13))
        case .image(let image):
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .scaleEffect(x: mirrored ? -1 : 1, y: 1)
        case .camera(let session, let live):
            ZStack {
                CameraPreview(session: session, mirrored: mirrored)
                    .opacity(live ? 1 : 0)
                if !live { BubbleSpinner(size: max(16, diameter * 0.13)) }
            }
        }
    }
}

/// A small spinner drawn by SwiftUI (so it shows in snapshots too).
struct BubbleSpinner: View {
    var size: CGFloat
    var body: some View {
        TimelineView(.animation) { context in
            let angle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360
            Circle()
                .trim(from: 0.08, to: 0.78)
                .stroke(Color.white.opacity(0.75), style: StrokeStyle(lineWidth: max(2, size * 0.12), lineCap: .round))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(angle))
        }
    }
}

/// AVCaptureVideoPreviewLayer in a layer-hosting view. Fills its frame (aspect fill).
/// Mirroring is a transform on the preview layer: it works before the session has a connection.
struct CameraPreview: NSViewRepresentable {
    var session: AVCaptureSession
    var mirrored: Bool

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView(session: session)
        view.logState("camera preview created")
        return view
    }
    func updateNSView(_ view: PreviewView, context: Context) {
        if view.previewLayer.session !== session { view.previewLayer.session = session }
        view.mirrored = mirrored
    }

    final class PreviewView: NSView {
        let previewLayer: AVCaptureVideoPreviewLayer
        var mirrored = true { didSet { needsLayout = true } }
        init(session: AVCaptureSession) {
            previewLayer = AVCaptureVideoPreviewLayer(session: session)
            previewLayer.videoGravity = .resizeAspectFill
            super.init(frame: .zero)
            wantsLayer = true
            layer?.addSublayer(previewLayer)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            matchScale()
            logState("camera preview moved to window")
        }

        // Moved to a display with another scale (a 1x external screen, back to Retina).
        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            matchScale()
            logState("camera preview backing changed")
        }

        /// A sublayer added by hand keeps contentsScale 1 on a 2x screen: the camera was drawn at
        /// half resolution and doubled (the blurry face, in the bubble and in the recording).
        private func matchScale() {
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            guard previewLayer.contentsScale != scale else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.contentsScale = scale
            CATransaction.commit()
        }

        /// For the black-bubble chase (capture): which layer, in which window, is the session live.
        func logState(_ what: String) {
            AppLog.info("\(what): layer \(ObjectIdentifier(previewLayer)) in window \(window?.windowNumber ?? 0) visible \(window?.isVisible ?? false), session running \(previewLayer.session?.isRunning ?? false), connection enabled \(previewLayer.connection?.isEnabled ?? false), bounds \(NSStringFromRect(bounds)), scale \(previewLayer.contentsScale) (window \(window?.backingScaleFactor ?? 0))")
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.setAffineTransform(.identity)
            previewLayer.frame = bounds
            previewLayer.setAffineTransform(CGAffineTransform(scaleX: mirrored ? -1 : 1, y: 1))
            CATransaction.commit()
        }
        // The bubble window handles the drag.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
