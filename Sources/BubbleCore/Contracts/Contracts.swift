// Shared contracts between the three tracks (capture, app/UI, QA).
// Owner: architect. Change this file only after telling the architect (sb send architect);
// every track compiles against it, so a change here is a change for everyone.
//
// Rule of thumb: values cross the seams, not framework objects. The one exception is the camera's
// AVCaptureSession, which the bubble window needs for its preview layer.

import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

// MARK: - Devices

/// A display the user can record. `frame` is in AppKit global points (origin bottom-left of the main display).
public struct DisplayInfo: Sendable, Hashable, Identifiable {
    public var id: CGDirectDisplayID
    public var name: String
    public var frame: CGRect
    public var scale: CGFloat
    public init(id: CGDirectDisplayID, name: String, frame: CGRect, scale: CGFloat) {
        self.id = id; self.name = name; self.frame = frame; self.scale = scale
    }
}

/// A camera or a microphone. `id` is AVCaptureDevice.uniqueID.
public struct DeviceInfo: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

@MainActor
public protocol DeviceCatalog: AnyObject {
    func displays() -> [DisplayInfo]
    func cameras() -> [DeviceInfo]
    func microphones() -> [DeviceInfo]
    /// The display under the mouse (default for the ⌥⇧L fast path).
    func displayWithMouse() -> DisplayInfo?
    /// Called on the main actor when cameras, mics or displays are added or removed.
    var onChange: (@MainActor () -> Void)? { get set }
}

// MARK: - Permissions

public enum Permission: String, Sendable, CaseIterable { case screen, camera, microphone }

public enum PermissionStatus: Sendable, Equatable {
    case notDetermined
    case granted
    case denied
    /// Screen recording was granted after launch: macOS applies it only after a relaunch.
    case needsRelaunch
}

@MainActor
public protocol PermissionsProviding: AnyObject {
    /// Never prompts.
    func status(_ permission: Permission) -> PermissionStatus
    /// Prompts (camera, mic) or registers the app and opens System Settings (screen).
    func request(_ permission: Permission) async -> PermissionStatus
    func openSystemSettings(_ permission: Permission)
    func relaunch()
}

// MARK: - Camera

/// The camera feed behind the bubble. The bubble window shows `session` with an
/// AVCaptureVideoPreviewLayer; the camera is never written to the file directly: the screen
/// capture records the bubble window (what you see is what is in the video).
@MainActor
public protocol CameraFeed: AnyObject {
    var session: AVCaptureSession { get }
    var isRunning: Bool { get }
    /// nil = the last used camera, else the system default.
    func start(cameraID: String?) async throws
    func stop()
    /// The camera was unplugged or taken away: hide the bubble, the recording goes on.
    var onDisconnected: (@MainActor () -> Void)? { get set }
    /// Frames flowing (true) or stopped (false) while the camera is on: interrupted, runtime error
    /// being recovered, camera taken. The bubble shows "Camera unavailable" while false.
    var onLiveChange: (@MainActor (Bool) -> Void)? { get set }
}

// MARK: - Recording

/// What the take records (docs/architecture.md §3.2). The bubble is in the video only where it
/// overlaps the recorded window or area: the app keeps it inside.
public enum CaptureSource: Sendable, Equatable {
    /// The whole display `RecordingOptions.displayID`.
    case display
    /// One window (from WindowPicking), with its own app's menus, sheets and popovers, cropped to
    /// the window's frame and followed when it moves or resizes; other apps' windows never cover
    /// it. `RecordingOptions.displayID` = the display it is on at start (PickedWindow.displayID).
    case window(CGWindowID)
    /// A fixed rectangle in AppKit global points (origin bottom-left of the main display), on
    /// `RecordingOptions.displayID`; the recorder clips it to that display.
    case area(CGRect)
}

public struct RecordingOptions: Sendable, Equatable {
    public var displayID: CGDirectDisplayID
    public var source: CaptureSource
    /// The bubble's window number (NSWindow.windowNumber). It is the only window of ours left in
    /// the video; every other window of the app (panel, countdown, hover controls, alerts) is
    /// excluded, including windows created during the take. nil = no camera at all.
    /// Set it whenever a camera exists, even if hidden at start. The window must be ordered in at
    /// start (capture looks it up among on-screen windows): during a take, hide it with
    /// alphaValue = 0, never orderOut; never recreate it; resizing is fine.
    public var bubbleWindowID: CGWindowID?
    /// nil = no microphone (silent video unless computer sound is on).
    public var microphoneID: String?
    public var captureComputerSound: Bool
    public var showClicks: Bool
    /// Folder for the file; the recorder picks the name ("Bubble 2026-11-06 at 14.22.05.mp4").
    public var folder: URL

    public init(displayID: CGDirectDisplayID, bubbleWindowID: CGWindowID?, microphoneID: String?,
                captureComputerSound: Bool, showClicks: Bool, folder: URL, source: CaptureSource = .display) {
        self.displayID = displayID; self.source = source
        self.bubbleWindowID = bubbleWindowID; self.microphoneID = microphoneID
        self.captureComputerSound = captureComputerSound; self.showClicks = showClicks; self.folder = folder
    }
}

public enum RecorderState: Sendable, Equatable {
    case idle
    case starting
    case recording
    case paused
    case finishing
}

public enum StopReason: Sendable, Equatable {
    case user
    case discarded
    case displayDisconnected
    case diskAlmostFull
    case screenPermissionRevoked
    case appQuitting
    /// The recorded window was closed (or its app quit). The file is kept.
    case windowClosed
    case failed(String)
}

public struct RecordingResult: Sendable, Equatable {
    public var url: URL
    /// Video length, paused time excluded.
    public var duration: TimeInterval
    public var bytes: Int64
    public var reason: StopReason
    public init(url: URL, duration: TimeInterval, bytes: Int64, reason: StopReason) {
        self.url = url; self.duration = duration; self.bytes = bytes; self.reason = reason
    }
}

public enum RecorderEvent: Sendable, Equatable {
    case stateChanged(RecorderState)
    /// Free space under 2 GB while recording; `minutesLeft` is an estimate at the current rate.
    case lowDisk(bytesLeft: Int64, minutesLeft: Int)
    case microphoneSwitched(name: String)
    case microphoneLost
    case computerSoundLost
    /// The recording ended without stop()/discard() being called (display unplugged, disk full,
    /// permission revoked, writer failure). The file is kept and playable.
    case stoppedOnItsOwn(RecordingResult)
    /// Window mode: the recorded window moved or resized; its frame now, AppKit global points.
    /// The video keeps its size (a resized window is letterboxed). Keep the bubble inside it.
    case recordedAreaChanged(CGRect)
    /// Window mode: the window can't be recorded now (design.md §11.4). The take is paused already
    /// (like a screen lock: no auto-resume, the app calls resume()).
    case recordedWindowHidden(WindowHiddenReason)
    /// Window mode: the window is visible again (the take stays paused until resume()).
    case recordedWindowShown
}

public enum RecorderError: Error, Sendable, Equatable {
    case screenPermissionMissing
    case displayNotFound
    /// Window mode: the window is gone, or not on screen, at start.
    case windowNotFound
    case notEnoughDiskSpace(bytesFree: Int64)
    case alreadyRecording
    case captureFailed(String)
}

/// Why a recorded window can't be recorded now.
public enum WindowHiddenReason: Sendable, Equatable {
    /// Its app is hidden (⌘H).
    case appHidden
    /// Minimized, or on another Space: macOS doesn't tell the two apart without Accessibility.
    case notOnScreen
    /// Moved to another display than the one recorded.
    case otherDisplay
}

/// A window the user chose to record.
public struct PickedWindow: Sendable, Equatable {
    public var id: CGWindowID
    public var title: String
    public var appName: String
    /// AppKit global points at pick time.
    public var frame: CGRect
    public var displayID: CGDirectDisplayID
    public init(id: CGWindowID, title: String, appName: String, frame: CGRect, displayID: CGDirectDisplayID) {
        self.id = id; self.title = title; self.appName = appName; self.frame = frame; self.displayID = displayID
    }
}

/// Lets the user choose a window to record (LiveWindowPicker: the system's content-sharing picker;
/// FakeWindowPicker in BubbleTesting). Bubble's own windows are never offered.
@MainActor
public protocol WindowPicking: AnyObject {
    /// false: window mode is not offered (macOS before 15.2).
    var isAvailable: Bool { get }
    /// nil: canceled. One pick at a time: a second call while one is up returns nil.
    func pickWindow() async -> PickedWindow?
}

/// The seam between the app and the capture engine. The app talks only to this; QA and the UI
/// use FakeRecorder (BubbleTesting) until LiveRecorder (BubbleCore/Capture) lands.
@MainActor
public protocol Recorder: AnyObject {
    var state: RecorderState { get }
    /// Seconds of video so far (paused time excluded). Poll it for the menu bar timer (4 Hz is fine).
    var elapsed: TimeInterval { get }
    /// Called on the main actor.
    var onEvent: (@MainActor (RecorderEvent) -> Void)? { get set }

    /// Starts capture and writing. Returns the file URL once the first frame is written.
    /// Throws before creating any file when a precondition fails (permission, display, disk < 1 GB).
    func start(_ options: RecordingOptions) async throws -> URL
    /// Pause/resume cut the paused time out of the video. The resume countdown is the app's job:
    /// call resume() when it ends.
    func pause()
    func resume()
    /// Finalizes the file (usually < 1 s) and returns it.
    func stop() async -> RecordingResult
    /// Stops and moves the file to the Trash.
    func discard() async
}
