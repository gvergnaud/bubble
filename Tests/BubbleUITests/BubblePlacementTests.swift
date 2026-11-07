// Owner: app/UI track. The bubble's placement math (design.md §6.3): corners with a 24 pt margin,
// snap within 64 pt, sizes, never off the recorded display.
import BubbleUI
import CoreGraphics
import Testing

@Suite struct BubblePlacementTests {
    // A display's usable area, not at the origin (second display, Dock at the bottom).
    let area = CGRect(x: 1512, y: 70, width: 2560, height: 1340)

    @Test func defaultIsMediumBottomLeftWithMargin() {
        let f = BubblePlacement.frame(for: .default, in: area)
        #expect(f == CGRect(x: 1512 + 24, y: 70 + 24, width: 180, height: 180))
    }

    @Test func sizes() {
        #expect(BubbleSize.small.diameter == 120)
        #expect(BubbleSize.medium.diameter == 180)
        #expect(BubbleSize.large.diameter == 260)
    }

    @Test(arguments: BubbleCorner.allCases)
    func everyCornerKeepsTheMargin(_ corner: BubbleCorner) {
        let f = BubblePlacement.frame(for: BubblePlace(size: .large, corner: corner), in: area)
        #expect(f.width == 260)
        #expect(min(f.minX - area.minX, area.maxX - f.maxX) == 24)
        #expect(min(f.minY - area.minY, area.maxY - f.maxY) == 24)
    }

    @Test func dropNearACornerSnaps() {
        // 50 pt right and 30 pt up from the top-right corner position: distance ≈ 58 < 64.
        let corner = BubblePlacement.cornerOrigin(.topRight, diameter: 180, in: area)
        let dropped = CGRect(x: corner.x - 50, y: corner.y - 30, width: 180, height: 180)
        let place = BubblePlacement.place(afterDropping: dropped, size: .medium, in: area)
        #expect(place.corner == .topRight)
    }

    @Test func dropFarFromCornersStaysPut() {
        let dropped = CGRect(x: area.midX - 90, y: area.midY - 90, width: 180, height: 180)
        let place = BubblePlacement.place(afterDropping: dropped, size: .medium, in: area)
        #expect(place.corner == nil)
        let f = BubblePlacement.frame(for: place, in: area)
        #expect(abs(f.midX - area.midX) < 0.5 && abs(f.midY - area.midY) < 0.5)
    }

    @Test func justOutsideSnapDistanceDoesNotSnap() {
        let corner = BubblePlacement.cornerOrigin(.bottomLeft, diameter: 180, in: area)
        let dropped = CGRect(x: corner.x + 70, y: corner.y, width: 180, height: 180)
        #expect(BubblePlacement.place(afterDropping: dropped, size: .medium, in: area).corner == nil)
    }

    @Test func dropHalfOffTheEdgeIsPulledBackInside() {
        let dropped = CGRect(x: area.minX - 60, y: area.midY, width: 180, height: 180)
        let place = BubblePlacement.place(afterDropping: dropped, size: .medium, in: area)
        let f = BubblePlacement.frame(for: place, in: area)
        #expect(area.contains(f))
    }

    @Test func dropOnAnotherDisplaySnapsBackToNearestCorner() {
        // Center far to the left of the area (the built-in display): nearest corner of this one.
        let dropped = CGRect(x: 400, y: 1200, width: 180, height: 180)
        let place = BubblePlacement.place(afterDropping: dropped, size: .medium, in: area)
        #expect(place.corner == .topLeft)
    }

    @Test func resizingKeepsTheCorner() {
        let place = BubblePlacement.resized(BubblePlace(size: .medium, corner: .bottomRight), to: .large)
        let f = BubblePlacement.frame(for: place, in: area)
        #expect(f.maxX == area.maxX - 24 && f.minY == area.minY + 24 && f.width == 260)
    }

    @Test func resizingAFreeBubbleKeepsItsCenterAndStaysInside() {
        let near = CGRect(x: area.maxX - 200, y: area.midY, width: 120, height: 120)
        var place = BubblePlacement.place(afterDropping: near, size: .small, in: area)
        #expect(place.corner == nil)
        place = BubblePlacement.resized(place, to: .large)
        let f = BubblePlacement.frame(for: place, in: area)
        #expect(area.contains(f))
    }

    @Test func freePlaceSurvivesAResolutionChange() {
        let dropped = CGRect(x: area.midX - 90, y: area.midY - 90, width: 180, height: 180)
        let place = BubblePlacement.place(afterDropping: dropped, size: .medium, in: area)
        let smaller = CGRect(x: 0, y: 0, width: 1280, height: 700)
        let f = BubblePlacement.frame(for: place, in: smaller)
        #expect(abs(f.midX - 640) < 0.5 && abs(f.midY - 350) < 0.5)
    }
}
