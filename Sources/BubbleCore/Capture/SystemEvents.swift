// What the system does to a take: lock, sleep, logout, displays and mics coming and going.
// Owner: capture track. Spec: docs/architecture.md §3.3, docs/design.md 7.2, 7.3, 7.5.
//
// Main actor: observers are added on start() and removed on stop(); every callback runs on the main actor.

import AppKit
import AVFoundation
import CoreGraphics
import Foundation

@MainActor
final class SystemEvents {
    /// Screen locked, Mac going to sleep, screens asleep: pause (no auto-resume).
    var onLockOrSleep: (@MainActor () -> Void)?
    /// Logout, restart, shutdown: stop and save.
    var onPowerOff: (@MainActor () -> Void)?
    /// Displays changed (plugged, unplugged, rearranged).
    var onDisplaysChanged: (@MainActor () -> Void)?
    /// A mic was unplugged or taken away: its uniqueID.
    var onMicrophoneGone: (@MainActor (String) -> Void)?

    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    func start() {
        guard tokens.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let local = NotificationCenter.default
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.onLockOrSleep?() }
        observe(workspace, NSWorkspace.willSleepNotification) { $0.onLockOrSleep?() }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.onLockOrSleep?() }
        observe(workspace, NSWorkspace.willPowerOffNotification) { $0.onPowerOff?() }
        observe(local, NSApplication.didChangeScreenParametersNotification) { $0.onDisplaysChanged?() }
        let token = local.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] note in
            guard let device = note.object as? AVCaptureDevice, device.hasMediaType(.audio) else { return }
            let id = device.uniqueID
            MainActor.assumeIsolated { self?.onMicrophoneGone?(id) }
        }
        tokens.append((local, token))
    }

    func stop() {
        for (center, token) in tokens { center.removeObserver(token) }
        tokens = []
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor (SystemEvents) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        tokens.append((center, token))
    }

    /// Is this display still connected? Asleep counts as connected (online, not active).
    static func isDisplayOnline(_ id: CGDirectDisplayID) -> Bool {
        displayList(CGGetOnlineDisplayList).contains(id)
    }

    /// Connected and awake.
    static func isDisplayActive(_ id: CGDirectDisplayID) -> Bool {
        displayList(CGGetActiveDisplayList).contains(id)
    }

    private static func displayList(_ get: (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError) -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard get(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard get(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}
