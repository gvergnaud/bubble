// Owner: app/UI track. A short message under the menu bar, top-right of the screen, like a
// notification but drawn by Bubble, so it is never in the video (every Bubble window but the bubble
// is excluded): "Now using MacBook Pro Microphone", "Press ⌥⇧C again to discard"...
import SwiftUI

public struct ToastView: View {
    var toast: Toast
    public static let width: CGFloat = 320

    public init(toast: Toast) { self.toast = toast }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(tint.opacity(0.16)))
            Text(toast.text)
                .font(.system(size: 13, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: Self.width)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .padding(16)
    }

    private var symbol: String {
        switch toast.icon {
        case .info: "info.circle.fill"
        case .mic: "mic.fill"
        case .camera: "video.slash.fill"
        case .disk: "internaldrive.fill"
        case .discard: "trash.fill"
        case .speaker: "speaker.slash.fill"
        }
    }

    private var tint: Color {
        switch toast.icon {
        case .disk: .orange
        case .discard: .red
        default: .accentColor
        }
    }
}
