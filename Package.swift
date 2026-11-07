// swift-tools-version: 6.0
// Bubble: a free, fully local screen recorder for macOS. See docs/architecture.md.
// Build with SwiftPM only (this Mac has the Command Line Tools, no Xcode): scripts/build-app.sh, scripts/check.sh.
import PackageDescription

let package = Package(
    name: "Bubble",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Bubble", targets: ["Bubble"]),
        .executable(name: "bubble-diag", targets: ["bubble-diag"]),
    ],
    targets: [
        // Capture track. No AppKit UI. Contracts/ is shared and owned by the architect.
        .target(name: "BubbleCore", path: "Sources/BubbleCore"),
        // App/UI track. Views and windows; every view renders from plain values so QA can snapshot it.
        .target(name: "BubbleUI", dependencies: ["BubbleCore"], path: "Sources/BubbleUI"),
        // App/UI track. Just the entry point. BubbleTesting is linked so BUBBLE_FAKE=1 can run the app on fakes.
        // BubbleEditor: main.swift builds the EditorService and hands BubbleUI a closure to open a recording.
        .executableTarget(name: "Bubble", dependencies: ["BubbleCore", "BubbleUI", "BubbleTesting", "BubbleEditor"], path: "Sources/Bubble"),
        // QA track. Fakes and synthetic media, usable by tests, previews and bubble-diag.
        .target(name: "BubbleTesting", dependencies: ["BubbleCore"], path: "Sources/BubbleTesting"),
        // QA track. CLI: synthetic recordings, crash tests, file checks. Never captures the real screen
        // unless called with `record` (one batched manual run, see docs/architecture.md).
        .executableTarget(name: "bubble-diag", dependencies: ["BubbleCore", "BubbleTesting"], path: "Sources/bubble-diag"),
        // Editor (docs/editor-architecture.md): local HTTP server, projects, waveform, export, transcription.
        // No AppKit, no SwiftPM dependencies. Server/ + Projects/ = E1, Media/ + Transcription/ = E2.
        .target(name: "BubbleEditor", dependencies: ["BubbleCore"], path: "Sources/BubbleEditor"),
        .testTarget(name: "BubbleEditorTests", dependencies: ["BubbleEditor"], path: "Tests/BubbleEditorTests"),
        .testTarget(name: "BubbleCoreTests", dependencies: ["BubbleCore", "BubbleTesting"], path: "Tests/BubbleCoreTests"),
        .testTarget(name: "BubbleUITests", dependencies: ["BubbleUI", "BubbleCore", "BubbleTesting"], path: "Tests/BubbleUITests"),
    ],
    swiftLanguageModes: [.v6]
)
