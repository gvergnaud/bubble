// Owner: app/UI track. The 3-2-1 (design.md §6.4): a big digit in a 160 pt dark translucent rounded
// square in the middle of the recorded display, a caption under it. Not recorded.
import SwiftUI

public struct CountdownView: View {
    var digit: Int
    /// Resuming a paused take: the caption says so.
    var resuming: Bool

    public static let squareSide: CGFloat = 160
    /// The window's size: the square plus the caption under it.
    public static let windowSize = CGSize(width: 340, height: 240)

    public init(digit: Int, resuming: Bool = false) {
        self.digit = digit; self.resuming = resuming
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
