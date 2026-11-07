// Owner: QA track. Proves offscreen rendering works in `swift test`; the real catalog replaces it.
import AppKit
import SwiftUI
import Testing

@MainActor @Test func offscreenRenderWorks() throws {
    let renderer = ImageRenderer(content: Text("Bubble").padding().background(Color.red))
    renderer.scale = 2
    #expect(renderer.cgImage != nil)
}
