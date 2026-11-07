// Owner: app/UI track. What the menu bar item shows (design.md §6.1): the template icon at idle,
// red dot + MM:SS while recording, grey pause glyph + frozen time when paused, a spinner while
// saving, a yellow ! when something stopped on its own. Hosted in the NSStatusItem's button,
// so the snapshot is the real thing.
import SwiftUI

public struct MenuBarLabelView: View {
    var label: MenuBarLabel

    public init(label: MenuBarLabel) { self.label = label }

    /// Readable on both menu bars: dark orange on light, yellow on dark.
    static let lowDiskColor = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .systemYellow
            : NSColor(srgbRed: 0.70, green: 0.36, blue: 0, alpha: 1)
    })

    public var body: some View {
        HStack(spacing: 5) {
            switch label {
            case .idle(let attention):
                MenuBarGlyphView(recording: false)
                if attention {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.black, .yellow)
                        .padding(.leading, -9)
                        .offset(y: -5)
                }
            case .countdown:
                MenuBarGlyphView(recording: false)
            case .recording(let time, let lowDisk):
                MenuBarGlyphView(recording: true)
                Text(time)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(lowDisk ? Self.lowDiskColor : Color.primary)
            case .paused(let time):
                Image(systemName: "pause.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Text(time)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            case .saving:
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.75)
                    .frame(width: 16, height: 16)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
        .fixedSize()
    }
}


