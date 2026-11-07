// Owner: E2 (media). docs/editor-architecture.md §4: a frame of the recording as a JPEG, shown by the
// page while the video loads (docs/editor-api.md §2, video.posterUrl).
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum Poster {
    public enum Failure: Error, Equatable {
        case noVideo
        case encodeFailed
    }

    /// JPEG of the frame at `seconds` (clamped inside the video), at most `maxWidth` px wide (never upscaled),
    /// rotation applied.
    public static func jpeg(of url: URL, at seconds: Double = 1, maxWidth: Int = 1280, quality: Double = 0.8) async throws -> Data {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let duration = try await asset.load(.duration).seconds
        let size = try await track.load(.naturalSize).applying(try await track.load(.preferredTransform))
        let width = abs(size.width), height = abs(size.height)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        if width > CGFloat(maxWidth), width > 0 {
            generator.maximumSize = CGSize(width: CGFloat(maxWidth), height: (height * CGFloat(maxWidth) / width).rounded())
        }
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        let t = duration.isFinite && duration > 0 ? min(max(0, seconds), duration / 2) : 0
        let (image, _) = try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600))
        return try encode(image, quality: quality)
    }

    static func encode(_ image: CGImage, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw Failure.encodeFailed }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure.encodeFailed }
        return data as Data
    }
}
