// Displays, cameras and mics, and their changes. Owner: capture track.
// Main actor. Never prompts for anything: listing devices needs no permission.

import AppKit
import AVFoundation
import CoreGraphics

@MainActor
public final class LiveDeviceCatalog: DeviceCatalog {
    public var onChange: (@MainActor () -> Void)?
    private var tokens: [NSObjectProtocol] = []

    public init() {
        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification,
                     NSApplication.didChangeScreenParametersNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange?() }
            })
        }
    }

    public func displays() -> [DisplayInfo] {
        NSScreen.screens.compactMap(Self.info)
    }

    /// The built-in (FaceTime) camera first, then the others. Desk View is left out.
    public func cameras() -> [DeviceInfo] {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video, position: .unspecified
        ).devices.filter { $0.deviceType != .deskViewCamera }
        let builtIn = devices.filter { $0.deviceType == .builtInWideAngleCamera }
        let others = devices.filter { $0.deviceType != .builtInWideAngleCamera }
        return (builtIn + others).map { DeviceInfo(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// The system default input first (the app's "automatic" choice takes `.first`), then the others.
    public func microphones() -> [DeviceInfo] {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio,
                                                       position: .unspecified).devices
        let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
        let sorted = devices.filter { $0.uniqueID == defaultID } + devices.filter { $0.uniqueID != defaultID }
        return sorted.map { DeviceInfo(id: $0.uniqueID, name: $0.localizedName) }
    }

    public func displayWithMouse() -> DisplayInfo? {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        return screen.flatMap(Self.info)
    }

    /// The system default mic's id, for a take started with "the default mic".
    public func defaultMicrophone() -> DeviceInfo? {
        AVCaptureDevice.default(for: .audio).map { DeviceInfo(id: $0.uniqueID, name: $0.localizedName) }
    }

    private static func info(_ screen: NSScreen) -> DisplayInfo? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return DisplayInfo(id: CGDirectDisplayID(number.uint32Value), name: screen.localizedName,
                           frame: screen.frame, scale: screen.backingScaleFactor)
    }
}
