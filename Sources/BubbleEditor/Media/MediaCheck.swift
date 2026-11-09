// Owner: E2 (media). docs/editor-open-video.md §4: can Bubble edit this video? Checked at open, before a
// project exists. AVFoundation's own answer (`isPlayable`, a video track, `isDecodable`), not a codec list,
// plus what the page and the export need to know about it.
import AVFoundation
import CoreMedia
import Foundation

public struct MediaInfo: Sendable, Equatable, Codable {
    /// "H.264", "HEVC", "ProRes 422", "AV1"... (the four-char code when unknown).
    public var codec: String
    /// Displayed size (rotation applied), pixels.
    public var width: Int
    public var height: Int
    /// The source's frame rate: its fastest frame interval, else its nominal rate (0 when unknown).
    public var fps: Double
    public var duration: Double
    /// HLG or PQ transfer (BT.2100): the export tone-maps it to SDR.
    public var hdr: Bool
    public var hasAudio: Bool
}

public enum MediaCheck {
    /// The containers Bubble edits.
    /// The containers Bubble names in its refusal. The check itself judges the content: whatever
    /// AVFoundation reads with a decodable video track opens; a sound file is "no video".
    public static let extensions: Set<String> = ["mp4", "mov", "m4v"]

    public enum Refusal: Error, Equatable, CustomStringConvertible {
        case missing
        /// Not an MP4 / MOV / M4V AVFoundation can read (`ext`: the file's extension, lowercase).
        case unsupportedContainer(ext: String)
        /// A container it reads, a video it can't decode (VP9; AV1 without a decoder).
        case undecodable(codec: String)
        case noVideo

        /// docs/editor-open-video.md §6 `error`.
        public var code: String {
            switch self {
            case .missing: "missing"
            case .unsupportedContainer, .undecodable: "unsupported_format"
            case .noVideo: "no_video"
            }
        }

        public var description: String {
            switch self {
            case .missing: "The video is missing: it was moved or deleted."
            case .unsupportedContainer(let ext):
                ext.isEmpty ? "Bubble can't open this file. It edits MP4, MOV and M4V videos. Convert it to MP4 first."
                    : "Bubble can't open .\(ext) files. It edits MP4, MOV and M4V videos. Convert it to MP4 first."
            case .undecodable(let codec): "Bubble can't read this video's format (\(codec)). Convert it to H.264 or HEVC MP4 first."
            case .noVideo: "This file has no video."
            }
        }
    }

    public static func inspect(_ url: URL) async throws(Refusal) -> MediaInfo {
        guard FileManager.default.fileExists(atPath: url.path) else { throw .missing }
        let ext = url.pathExtension.lowercased()
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        do {
            let (playable, readable) = try await asset.load(.isPlayable, .isReadable)
            guard playable || readable else { throw Refusal.unsupportedContainer(ext: ext) }
            guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw Refusal.noVideo }
            let (formats, decodable, size, transform, characteristics) = try await video.load(
                .formatDescriptions, .isDecodable, .naturalSize, .preferredTransform, .mediaCharacteristics)
            let codec = formats.first.map { codecName(CMFormatDescriptionGetMediaSubType($0)) } ?? "unknown"
            guard decodable else { throw Refusal.undecodable(codec: codec) }
            let shown = CGRect(origin: .zero, size: size).applying(transform).size
            let hdr = characteristics.contains(.containsHDRVideo) || formats.contains(where: isHDR)
            let audio = await soundTracks(of: asset)
            let duration = try await asset.load(.duration).seconds
            return MediaInfo(codec: codec, width: Int(abs(shown.width).rounded()), height: Int(abs(shown.height).rounded()),
                             fps: await frameRate(of: video, in: asset), duration: duration.isFinite ? duration : 0,
                             hdr: hdr, hasAudio: !audio.isEmpty)
        } catch let refusal as Refusal {
            throw refusal
        } catch {
            throw .unsupportedContainer(ext: ext)   // AVFoundation can't parse it
        }
    }

    /// The sound tracks AVFoundation can decode. One it can't (a codec it lists but can't read) counts
    /// as no sound everywhere (export video only, transcript `no_sound`) instead of failing late in
    /// AudioJoiner / AudioExtract. Vorbis or MP2 in an MP4 don't even show up as audio tracks.
    public static func soundTracks(of asset: AVAsset) async -> [AVAssetTrack] {
        var out: [AVAssetTrack] = []
        for track in (try? await asset.loadTracks(withMediaType: .audio)) ?? [] where (try? await track.load(.isDecodable)) == true {
            out.append(track)
        }
        return out
    }

    /// The track's frame rate from its first frames' times (compressed samples, nothing decoded), else
    /// its nominal rate. 0 when unknown.
    public static func frameRate(of track: AVAssetTrack, in asset: AVAsset) async -> Double {
        let nominal = Double((try? await track.load(.nominalFrameRate)) ?? 0)
        nonisolated(unsafe) let readAsset = asset, readTrack = track
        let times = (try? await BlockingRead.run { checkCancellation -> [Double] in
            let reader = try AVAssetReader(asset: readAsset)
            let output = AVAssetReaderTrackOutput(track: readTrack, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else { return [] }
            defer { reader.cancelReading() }
            var times: [Double] = []
            while times.count < 600, let sample = output.copyNextSampleBuffer() {
                try checkCancellation()
                guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
                times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
            }
            return times
        }) ?? []
        return frameRate(times: times, nominal: nominal)
    }

    /// The median interval between frames under 0.1 s apart: a variable-rate screen recording's capture
    /// rate (its pauses on a still screen don't count; its average can be 8 fps), robust to a few
    /// jittery or doubled timestamps. The nominal rate when there are too few frames.
    static func frameRate(times: [Double], nominal: Double) -> Double {
        let sorted = times.filter(\.isFinite).sorted()
        let intervals = zip(sorted, sorted.dropFirst()).map { $1 - $0 }.filter { $0 > 1e-4 && $0 < 0.1 }.sorted()
        guard intervals.count >= 5 else { return nominal.isFinite && nominal > 0 ? nominal : 0 }
        return 1 / intervals[intervals.count / 2]
    }

    static func isHDR(_ format: CMFormatDescription) -> Bool {
        guard let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        else { return false }
        return transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
            || transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
    }

    static func codecName(_ subtype: FourCharCode) -> String {
        switch subtype {
        case kCMVideoCodecType_H264: "H.264"
        case kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVCWithAlpha, 0x6865_7631 /* hev1 */: "HEVC"
        case kCMVideoCodecType_AppleProRes422: "ProRes 422"
        case kCMVideoCodecType_AppleProRes422HQ: "ProRes 422 HQ"
        case kCMVideoCodecType_AppleProRes422LT: "ProRes 422 LT"
        case kCMVideoCodecType_AppleProRes422Proxy: "ProRes 422 Proxy"
        case kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes4444XQ: "ProRes 4444"
        case 0x6176_3031 /* av01 */: "AV1"
        case 0x7670_3039 /* vp09 */: "VP9"
        case kCMVideoCodecType_MPEG4Video: "MPEG-4"
        case kCMVideoCodecType_JPEG: "Motion JPEG"
        default:
            String(String.UnicodeScalarView([24, 16, 8, 0].compactMap { Unicode.Scalar(UInt8((subtype >> $0) & 0xFF)) }))
                .trimmingCharacters(in: .whitespaces)
        }
    }
}
