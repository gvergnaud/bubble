// Owner: app/UI track. The Recordings window (design.md §10.3): row wording, and its snapshots
// (list, empty, unreadable row) plus the main menus, for the designer.
import AppKit
import BubbleCore
import BubbleTesting
import BubbleUI
import CoreVideo
import SwiftUI
import Testing
import VideoToolbox

@Suite struct RecordingFormatTests {
    let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Paris")!; return c }()
    func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    @Test func when() {
        let now = date(2026, 11, 6, 15, 0)
        #expect(RecordingFormat.when(date(2026, 11, 6, 14, 22), now: now, calendar: cal) == "Today at 14:22")
        #expect(RecordingFormat.when(date(2026, 11, 5, 9, 10), now: now, calendar: cal) == "Yesterday at 09:10")
        #expect(RecordingFormat.when(date(2026, 11, 1, 17, 3), now: now, calendar: cal) == "Sunday at 17:03")
        #expect(RecordingFormat.when(date(2026, 10, 20, 17, 3), now: now, calendar: cal).contains("2026"))
    }

    @Test func durationAndSubtitle() {
        #expect(RecordingFormat.duration(252) == "4:12")
        #expect(RecordingFormat.duration(3723) == "1:02:03")
        let url = URL(fileURLWithPath: "/tmp/Bubble 2026-11-06 at 14.22.05.mp4")
        let bad = RecordingItem(url: url, date: Date(), bytes: 186_000_000, unreadable: true)
        #expect(RecordingFormat.subtitle(bad, now: Date()).hasPrefix("Can't read this file · "))
        #expect(bad.title == "Bubble 2026-11-06 at 14.22.05")
    }
}

@MainActor @Suite struct RecordingsSnapshots {
    static func frame(_ index: Int) -> CGImage? {
        let pb = SyntheticFrames.frame(width: 384, height: 216, index: index * 40)
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &image)
        return image
    }

    static func state(unreadable: Bool = false) -> RecordingsState {
        let now = Date()
        let day: TimeInterval = 86_400
        let folder = URL(fileURLWithPath: "/Users/me/Movies/Bubble")
        func item(_ name: String, _ ago: TimeInterval, _ dur: TimeInterval?, _ mb: Int64, thumb: Int?, bad: Bool = false) -> RecordingItem {
            RecordingItem(url: folder.appendingPathComponent(name + ".mp4"), date: now.addingTimeInterval(-ago), bytes: mb * 1_000_000,
                          duration: dur, thumbnail: thumb.flatMap(frame), unreadable: bad)
        }
        var items = [
            item("Bubble 2026-11-06 at 14.22.05", 1800, 252, 186, thumb: 1),
            item("Demo for Camille", day + 3600, 768, 610, thumb: 2),
            item("Bubble 2026-11-02 at 17.03.44", 4 * day, 52, 31, thumb: 3),
            item("Bubble 2026-10-12 at 10.00.00 a very long name that has to be cut in the middle", 25 * day, nil, 12, thumb: nil),
        ]
        if unreadable { items.insert(item("Bubble 2026-11-06 at 15.01.10", 600, nil, 4, thumb: nil, bad: true), at: 0) }
        return RecordingsState(folderPath: "~/Movies/Bubble", items: items, now: now)
    }

    static let icon = NSImage(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/AppIcon.icns"))

    @Test func recordingsWindowStates() {
        let selected: Set<URL> = [Self.state().items[0].url]
        Snap.render("recordings-list", size: CGSize(width: 720, height: 520)) {
            RecordingsView(state: Self.state(), selection: .constant(selected), icon: Self.icon)
        }
        Snap.render("recordings-unreadable-row", size: CGSize(width: 720, height: 520)) {
            RecordingsView(state: Self.state(unreadable: true), selection: .constant([]), icon: Self.icon)
        }
        Snap.render("recordings-empty", size: CGSize(width: 720, height: 520)) {
            RecordingsView(state: RecordingsState(folderPath: "~/Movies/Bubble", items: []), selection: .constant([]), icon: Self.icon)
        }
        Snap.render("recordings-min-size", size: CGSize(width: 480, height: 360)) {
            RecordingsView(state: Self.state(), selection: .constant([]), icon: Self.icon)
        }
    }

    /// At rest with nothing selected, as the real menus validate: no take (Pause, Discard off),
    /// no selection (Open, Show in Finder, Move to Trash, Copy off).
    static let offAtRest: Set<String> = ["Pause", "Discard…", "Open", "Show in Finder", "Move to Trash", "Copy"]

    @Test func subtitleWording() {
        #expect(RecordingsState(folderPath: "~/Movies/Bubble", items: []).subtitle == "~/Movies/Bubble")
        let one = RecordingItem(url: URL(fileURLWithPath: "/a.mp4"), date: Date(), bytes: 1)
        #expect(RecordingsState(folderPath: "~/Movies/Bubble", items: [one]).subtitle == "~/Movies/Bubble · 1 recording")
    }

    @Test func bubbleCameraUnavailable() {
        for size in [BubbleSize.small, .medium] {
            Snap.render("bubble-camera-unavailable-\(size.letter.lowercased())", backdrop: .desktop) {
                BubbleView(content: .waiting, diameter: size.diameter, unavailable: true)
            }
        }
    }

    @Test func mainMenus() {
        let menu = AppDelegate.mainMenu()
        for top in menu.items {
            guard let sub = top.submenu else { continue }
            let rows = sub.items.enumerated().map { i, item -> MenuMock.Row in
                if item.isSeparatorItem { return MenuMock.Row(id: i, title: nil, shortcut: nil, enabled: true, label: false) }
                return MenuMock.Row(id: i, title: item.title, shortcut: Self.shortcut(item),
                                    enabled: !Self.offAtRest.contains(item.title), label: false)
            }
            Snap.render("main-menu-\(top.title.lowercased())") {
                VStack(alignment: .leading, spacing: 0) {
                    Text(top.title).font(.system(size: 13, weight: .semibold)).padding(.horizontal, 22).padding(.top, 10)
                    MenuMock(rows: rows)
                }
            }
        }
    }

    static func shortcut(_ item: NSMenuItem) -> String? {
        guard !item.keyEquivalent.isEmpty else { return nil }
        var s = ""
        let m = item.keyEquivalentModifierMask
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        let key = item.keyEquivalent == "\u{8}" ? "⌫" : item.keyEquivalent.uppercased()
        return s + key
    }
}
