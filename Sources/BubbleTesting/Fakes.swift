// Owner: QA track. Fakes for the device, camera and permission seams (Contracts.swift).
// They touch no hardware: FakeCameraFeed's session has no input and is never started.
import AVFoundation
import BubbleCore
import CoreGraphics
import Foundation

// MARK: - Devices

@MainActor
public final class FakeDeviceCatalog: DeviceCatalog {
    public var displayList: [DisplayInfo]
    public var cameraList: [DeviceInfo]
    public var microphoneList: [DeviceInfo]
    /// nil = the first display.
    public var mouseDisplayID: CGDirectDisplayID?
    public var onChange: (@MainActor () -> Void)?

    public init(displays: [DisplayInfo] = [FakeDeviceCatalog.builtIn],
                cameras: [DeviceInfo] = [FakeDeviceCatalog.faceTime],
                microphones: [DeviceInfo] = [FakeDeviceCatalog.builtInMic],
                mouseDisplayID: CGDirectDisplayID? = nil) {
        self.displayList = displays; self.cameraList = cameras; self.microphoneList = microphones
        self.mouseDisplayID = mouseDisplayID
    }

    public func displays() -> [DisplayInfo] { displayList }
    public func cameras() -> [DeviceInfo] { cameraList }
    public func microphones() -> [DeviceInfo] { microphoneList }
    public func displayWithMouse() -> DisplayInfo? {
        guard let id = mouseDisplayID else { return displayList.first }
        return displayList.first { $0.id == id }
    }

    /// Test helper: devices come and go (unplug a display, AirPods leave).
    public func change(displays: [DisplayInfo]? = nil, cameras: [DeviceInfo]? = nil, microphones: [DeviceInfo]? = nil) {
        if let displays { displayList = displays }
        if let cameras { cameraList = cameras }
        if let microphones { microphoneList = microphones }
        onChange?()
    }

    // Stock devices, named like the real ones on a MacBook Pro.
    public static let builtIn = DisplayInfo(id: 1, name: "Built-in Retina Display",
                                            frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2)
    public static let studioDisplay = DisplayInfo(id: 2, name: "Studio Display",
                                                  frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), scale: 2)
    public static let faceTime = DeviceInfo(id: "fake-camera-facetime", name: "FaceTime HD Camera")
    public static let continuity = DeviceInfo(id: "fake-camera-iphone", name: "Gabriel’s iPhone Camera")
    public static let builtInMic = DeviceInfo(id: "fake-mic-builtin", name: "MacBook Pro Microphone")
    public static let airPods = DeviceInfo(id: "fake-mic-airpods", name: "AirPods Pro")
}

// MARK: - Permissions

@MainActor
public final class FakePermissions: PermissionsProviding {
    public var statuses: [Permission: PermissionStatus]
    /// What request(_:) turns a permission into (default: granted; screen: needsRelaunch, like macOS).
    public var answers: [Permission: PermissionStatus]
    public private(set) var requested: [Permission] = []
    public private(set) var openedSettings: [Permission] = []
    public private(set) var relaunchCount = 0

    public init(_ statuses: [Permission: PermissionStatus] = [:],
                answers: [Permission: PermissionStatus] = [.screen: .needsRelaunch, .camera: .granted, .microphone: .granted]) {
        self.statuses = statuses; self.answers = answers
    }
    public static func allGranted() -> FakePermissions {
        FakePermissions([.screen: .granted, .camera: .granted, .microphone: .granted])
    }

    public func status(_ permission: Permission) -> PermissionStatus { statuses[permission] ?? .notDetermined }
    public func request(_ permission: Permission) async -> PermissionStatus {
        requested.append(permission)
        let s = answers[permission] ?? .granted
        statuses[permission] = s
        return s
    }
    public func openSystemSettings(_ permission: Permission) { openedSettings.append(permission) }
    public func relaunch() { relaunchCount += 1 }
}

// MARK: - Camera

@MainActor
public final class FakeCameraFeed: CameraFeed {
    /// No input, never started: AVCaptureVideoPreviewLayer(session:) shows nothing, which is fine
    /// for logic tests. Snapshots use a placeholder image instead (SyntheticFrames.placeholderFace).
    public let session = AVCaptureSession()
    public private(set) var isRunning = false
    public private(set) var startedWith: [String?] = []
    public private(set) var stopCount = 0
    /// Set to make start() throw (camera busy, denied).
    public var startError: Error?
    public var onDisconnected: (@MainActor () -> Void)?
    public var onLiveChange: (@MainActor (Bool) -> Void)?

    public init() {}

    public func start(cameraID: String?) async throws {
        startedWith.append(cameraID)
        if let startError { throw startError }
        isRunning = true
    }
    public func stop() { isRunning = false; stopCount += 1 }

    /// Test helper: the camera is unplugged mid-take.
    public func simulateDisconnect() { isRunning = false; onDisconnected?() }

    /// Test helper: frames stop (false: interrupted, taken by another app, recovering from an
    /// error) or flow again (true) while the camera stays on. The bubble shows "Camera unavailable".
    public func simulateLive(_ live: Bool) { onLiveChange?(live) }
}

public struct FakeError: Error, Equatable, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}
