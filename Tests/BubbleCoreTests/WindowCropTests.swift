// Owner: QA track. Window/area mode end to end on synthetic frames (no screen capture): a window's
// frame → CaptureGeometry's crop on its display → the encoder settings the engine uses → a file
// that has exactly that size, plays, decodes every frame and keeps a constant frame rate.
// The geometry's own rules are capture's CaptureGeometryTests; this checks they make good files.
import BubbleCore
import BubbleTesting
import CoreGraphics
import Foundation
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct WindowCropTests {
    /// A 1512×982 display (MacBook Pro 14" default) at 2×, its CG global bounds.
    let display = CGRect(x: 0, y: 0, width: 1512, height: 982)

    @Test func aWindowWithOddPointsMakesAnEvenSizedFileThatPlays() async throws {
        // AppKit global frame of a window (odd, fractional points), on the main display.
        let window = CGRect(x: 211.5, y: 140.25, width: 801.5, height: 517.3)
        let cg = CaptureGeometry.cgGlobal(fromAppKit: window, mainDisplayHeight: display.height)
        let crop = try #require(CaptureGeometry.crop(cg, onDisplay: display))
        let settings = CaptureGeometry.videoSettings(cropSize: crop.size, scale: 2)
        #expect(settings.width % 2 == 0 && settings.height % 2 == 0, "\(settings)")
        #expect(abs(Double(settings.width) - crop.width * 2) <= 2 && abs(Double(settings.height) - crop.height * 2) <= 2, "native pixels: \(settings) for \(crop)")

        let url = tempMovie("window-crop"); defer { cleanUp(url) }
        let errors = ErrorBox()
        try await SyntheticTake(seconds: 3, settings: settings).write(to: url, errors: errors)
        #expect(errors.errors.isEmpty, "\(errors.errors)")
        let r = await MediaProbe.inspect(url)
        #expect(r.playable && r.errors.isEmpty, "\(r)")
        #expect(r.width == settings.width && r.height == settings.height, "the file has the crop's size: \(r)")
        #expect(abs(r.decodedFrames - 90) <= 1 && r.maxFrameGap < 0.04, "\(r)")
        #expect(abs(r.audioSeconds - 3) <= 0.1, "\(r)")
    }

    @Test func aWindowBiggerThan4KIsCappedAt3840() async throws {
        // A 5K external display (2560×1440 points at 2×), a window nearly as big.
        let fiveK = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
        let crop = try #require(CaptureGeometry.crop(CGRect(x: 1520, y: 30, width: 2500, height: 1380), onDisplay: fiveK))
        let settings = CaptureGeometry.videoSettings(cropSize: crop.size, scale: 2)
        #expect(max(settings.width, settings.height) <= 3840, "\(settings)")
        #expect(settings.width % 2 == 0 && settings.height % 2 == 0, "\(settings)")
        let aspect = Double(settings.width) / Double(settings.height), want = crop.width / crop.height
        #expect(abs(aspect - want) < 0.01, "aspect kept: \(settings) for \(crop)")

        let url = tempMovie("window-4k"); defer { cleanUp(url) }
        let errors = ErrorBox()
        try await SyntheticTake(seconds: 1, audio: false, settings: settings).write(to: url, errors: errors)
        #expect(errors.errors.isEmpty, "\(errors.errors)")
        let r = await MediaProbe.inspect(url)
        #expect(r.playable && r.width == settings.width && r.height == settings.height, "\(r)")
        #expect(abs(r.decodedFrames - 30) <= 1, "\(r)")
    }

    @Test func aWindowHalfOffTheDisplayIsClippedAndOneFullyOffIsNot() throws {
        let half = CGRect(x: 1200, y: 600, width: 800, height: 600)    // runs off the right and bottom edges
        let crop = try #require(CaptureGeometry.crop(half, onDisplay: display))
        #expect(crop.maxX <= display.width && crop.maxY <= display.height, "clipped to the display: \(crop)")
        #expect(crop == CGRect(x: 1200, y: 600, width: 312, height: 382), "\(crop)")
        #expect(CaptureGeometry.crop(CGRect(x: 2000, y: 100, width: 400, height: 300), onDisplay: display) == nil)
        let s = CaptureGeometry.videoSettings(cropSize: crop.size, scale: 2)
        #expect(s.width == 624 && s.height == 764, "\(s)")
    }

    @Test func anAreaOnASecondDisplayIsInThatDisplaysPoints() throws {
        // A display left of the main one (negative x in CG global points).
        let left = CGRect(x: -1920, y: -98, width: 1920, height: 1080)
        let area = CGRect(x: -1700, y: 100, width: 1280, height: 720)
        let crop = try #require(CaptureGeometry.crop(area, onDisplay: left))
        #expect(crop == CGRect(x: 220, y: 198, width: 1280, height: 720), "display-local, top-left origin: \(crop)")
        let s = CaptureGeometry.videoSettings(cropSize: crop.size, scale: 1)
        #expect(s.width == 1280 && s.height == 720, "\(s)")
    }
}
