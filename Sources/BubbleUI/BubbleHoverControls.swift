// Owner: app/UI track. The bubble controls shown on hover (design.md §6.3): S / M / L at the top,
// ⦸ (camera off) at the top-right. Drawn in a separate window laid exactly over the bubble window,
// excluded from the video. Transparent everywhere but the buttons, so a drag on the face goes
// through to the bubble window below.
import SwiftUI

public struct BubbleHoverControlsView: View {
    var diameter: CGFloat
    var size: BubbleSize
    var onSize: (BubbleSize) -> Void
    var onCameraOff: () -> Void

    public init(diameter: CGFloat, size: BubbleSize, onSize: @escaping (BubbleSize) -> Void = { _ in },
                onCameraOff: @escaping () -> Void = {}) {
        self.diameter = diameter; self.size = size; self.onSize = onSize; self.onCameraOff = onCameraOff
    }

    public var body: some View {
        let r = diameter / 2
        // ⦸ sits on the ring, top-right (40° above the horizontal, so it clears the S/M/L pill on S).
        let angle = 40.0 * Double.pi / 180
        ZStack {
            Color.clear
            sizePicker
                .offset(y: -r + (compact ? 31 : 27))
            HoverIconButton(systemName: "video.slash.fill", help: "Hide camera", compact: compact, action: onCameraOff)
                .offset(x: r * cos(angle), y: -r * sin(angle))
        }
        .frame(width: diameter, height: diameter)
        .padding(BubbleView.shadowPadding)
    }

    /// The S bubble (120 pt) gets smaller controls.
    private var compact: Bool { diameter < 150 }

    private var sizePicker: some View {
        HStack(spacing: compact ? 0 : 2) {
            ForEach(BubbleSize.allCases, id: \.self) { s in
                Button { onSize(s) } label: {
                    Text(s.letter)
                        .font(.system(size: compact ? 10 : 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(s == size ? Color.black : Color.white)
                        .frame(width: compact ? 19 : 22, height: compact ? 18 : 20)
                        .background(Capsule().fill(s == size ? Color.white : Color.clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(s.name)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.black.opacity(0.62)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
    }
}

struct HoverIconButton: View {
    var systemName: String
    var help: String
    var compact = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: compact ? 9 : 10, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: compact ? 22 : 26, height: compact ? 22 : 26)
                .background(Circle().fill(Color.black.opacity(0.62)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
