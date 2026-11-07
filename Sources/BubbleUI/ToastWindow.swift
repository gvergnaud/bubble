// Owner: app/UI track. Shows a Toast at the top-right of the screen with the mouse for 4 s.
// One at a time: a new toast replaces the current one. Never recorded, never takes the focus.
import AppKit
import SwiftUI

@MainActor
final class ToastWindowController {
    private let panel = FloatingPanel(level: .statusBar)
    private let host = PassiveHostingView(rootView: ToastView(toast: Toast(.info, "")))
    private var hideWork: DispatchWorkItem?

    init() {
        panel.contentView = host
        panel.title = "Bubble message"
        panel.ignoresMouseEvents = true
    }

    func show(_ toast: Toast, seconds: TimeInterval = 4) {
        host.rootView = ToastView(toast: toast)
        let size = host.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? .zero
        let frame = NSRect(x: area.maxX - size.width, y: area.maxY - size.height, width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hide() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func hide() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { if self?.panel.alphaValue == 0 { self?.panel.orderOut(nil) } }
        })
    }
}
