// Owner: app/UI track. Shows CountdownView in the middle of the recorded display while the model is
// in a countdown phase. Click = start now. Esc/Return come from Hotkeys (registered only during the
// countdown) so the user's app keeps the focus.
import AppKit
import BubbleCore
import SwiftUI

@MainActor
final class CountdownWindowController {
    private let model: AppModel
    private let panel = FloatingPanel(level: .screenSaver)
    private let host = ClickableHostingView(rootView: CountdownView(digit: 3))
    var onVisibleChange: ((Bool) -> Void)?
    private var visible = false

    init(model: AppModel) {
        self.model = model
        panel.contentView = host
        panel.title = "Bubble countdown"
        host.onClick = { [weak self] in self?.model.skipCountdown() }
        trackChanges { [weak self] in self?.apply() }
    }

    private func apply() {
        guard let digit = model.phase.countdownDigit, let display = model.recordingDisplay else {
            if visible {
                visible = false
                onVisibleChange?(false)
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.12
                    panel.animator().alphaValue = 0
                }, completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        if self?.visible == false { self?.panel.orderOut(nil) }
                    }
                })
            }
            return
        }
        let resuming: Bool = if case .resumeCountdown = model.phase { true } else { false }
        withAnimation(.spring(duration: 0.3)) {
            host.rootView = CountdownView(digit: digit, resuming: resuming)
        }
        let screen = NSScreen.with(displayID: display.id)?.frame ?? display.frame
        let size = CountdownView.windowSize
        panel.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
        if !visible {
            visible = true
            onVisibleChange?(true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                panel.animator().alphaValue = 1
            }
        }
    }
}

final class ClickableHostingView<Content: View>: NSHostingView<Content> {
    var onClick: (() -> Void)?
    required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = []
    }
    @MainActor required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) { onClick?() }
}
