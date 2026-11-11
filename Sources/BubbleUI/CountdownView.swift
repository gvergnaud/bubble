// Owner: app/UI track. The 3-2-1 (design.md §6.4): a big digit in a 160 pt dark translucent rounded
// square in the middle of the recorded display, a caption under it. Not recorded.
import SwiftUI

public struct CountdownView: View {
    var digit: Int
    /// Resuming a paused take: the caption says so.
    var resuming: Bool
    /// What the take records, under the digit (design.md §11.6): "Full screen", "Safari — Pull
    /// request #42", "Area · 1280 × 720".
    var source: String?

    public static let squareSide: CGFloat = 160
    /// The window's size: the square, the source line and the caption under it.
    public static let windowSize = CGSize(width: 420, height: 270)

    public init(digit: Int, resuming: Bool = false, source: String? = nil) {
        self.digit = digit; self.resuming = resuming; self.source = source
    }

    public var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 36, style: .continuous)
                    .fill(Color.black.opacity(0.84))
                RoundedRectangle(cornerRadius: 36, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                Text("\(digit)")
                    .font(.system(size: 96, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(countsDown: true))
                    .id(digit)
            }
            .frame(width: Self.squareSide, height: Self.squareSide)
            .shadow(color: .black.opacity(0.3), radius: 18, y: 6)

            if let source {
                Text(source)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.84)))
                    .frame(maxWidth: Self.windowSize.width - 20)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(resuming ? "click to resume now · Esc to stay paused"
                          : "click to start now · Esc to cancel")
                .lineLimit(1)
                .fixedSize()
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.black.opacity(0.78)))
        }
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        .environment(\.colorScheme, .dark)
    }
}
