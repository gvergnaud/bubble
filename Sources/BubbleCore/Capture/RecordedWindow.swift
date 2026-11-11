// Where a window is now, from the window server. Owner: capture track.
// Spec: docs/architecture.md §3.4. No ScreenCaptureKit, no permission prompt; any thread.

import AppKit
import CoreGraphics

public enum RecordedWindow {
    /// The window's frame (AppKit global points) and the display holding most of it, or nil if
    /// it is gone, its app quit or is hidden, or it is not on screen (minimized, other Space).
    /// The app calls it just before the countdown: the window may have moved since the pick.
    public static func current(_ id: CGWindowID) -> (frame: CGRect, displayID: CGDirectDisplayID)? {
        guard let info = info(id), info.isOnScreen,
              let app = NSRunningApplication(processIdentifier: info.ownerPID), !app.isTerminated, !app.isHidden
        else { return nil }
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        return (CaptureGeometry.appKitGlobal(fromCG: info.bounds, mainDisplayHeight: mainHeight),
                LiveWindowPicker.displayHoldingMost(of: info.bounds))
    }

    /// The window server's entry for the window: CG global bounds, on screen, owner. nil once the
    /// window is destroyed. A minimized window, a window of a hidden app or on another Space is
    /// still described (not on screen); CGWindowListCopyWindowInfo(.optionIncludingWindow) drops
    /// those, so it would read a minimize as a close (found in the real run).
    static func info(_ id: CGWindowID) -> (bounds: CGRect, isOnScreen: Bool, ownerPID: pid_t)? {
        var ids: [UnsafeRawPointer?] = [UnsafeRawPointer(bitPattern: UInt(id))]
        guard let array = CFArrayCreate(nil, &ids, 1, nil),
              let list = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]],
              let info = list.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }),
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
              let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { return nil }
        // Present (true) only while the window is on screen.
        let onScreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
        return (bounds, onScreen, pid)
    }
}
