// Owner: QA track. Synthetic video frames and audio for tests and bubble-diag: no screen, camera or mic.
import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation

// MARK: - Video

/// BGRA CVPixelBuffers that look like a screen: a light page of small text (to judge sharpness),
/// a frame counter, and a moving block (so frames differ). Same as ScreenCaptureKit's format.
public enum SyntheticFrames {
    /// One IOSurface-backed BGRA buffer drawn for `index`. Deterministic: same index, same pixels.
    public static func frame(width: Int, height: Int, index: Int, label: String = "Bubble synthetic") -> CVPixelBuffer {
        let pb = makeBuffer(width: width, height: height)
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        draw(in: ctx, width: width, height: height, index: index, label: label)
        return pb
    }

    public static func makeBuffer(width: Int, height: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                                      kCVPixelBufferCGImageCompatibilityKey: true,
                                      kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        let rc = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        precondition(rc == kCVReturnSuccess && pb != nil, "CVPixelBufferCreate failed: \(rc)")
        return pb!
    }

    static func draw(in ctx: CGContext, width: Int, height: Int, index: Int, label: String) {
        let w = CGFloat(width), h = CGFloat(height)
        ctx.setFillColor(CGColor(srgbRed: 0.97, green: 0.97, blue: 0.96, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // A "window" title bar.
        ctx.setFillColor(CGColor(srgbRed: 0.88, green: 0.88, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: h - h * 0.06, width: w, height: h * 0.06))
        // Lines of small text: the sharpness target.
        let fontSize = max(10, h / 70)
        let font = CTFontCreateWithName("Menlo" as CFString, fontSize, nil)
        let line = "func record(_ screen: Display) -> URL { // The quick brown fox jumps over the lazy dog 0123456789"
        var y = h - h * 0.06 - fontSize * 2
        var n = 0
        while y > fontSize * 3 {
            drawText("\(String(format: "%03d", n))  \(line)", at: CGPoint(x: fontSize, y: y), font: font,
                     color: CGColor(gray: 0.12, alpha: 1), in: ctx)
            y -= fontSize * 1.6; n += 1
        }
        // A moving block: the frame differs from the previous one.
        let bw = w * 0.08
        let x = CGFloat(index * 7 % max(1, Int(w - bw)))
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.45, blue: 0.95, alpha: 1))
        ctx.fill(CGRect(x: x, y: h * 0.45, width: bw, height: bw * 0.5))
        // Frame counter, big.
        let big = CTFontCreateWithName("Menlo-Bold" as CFString, max(14, h / 18), nil)
        drawText("\(label)  #\(index)", at: CGPoint(x: fontSize, y: fontSize), font: big,
                 color: CGColor(srgbRed: 0.85, green: 0.15, blue: 0.1, alpha: 1), in: ctx)
    }

    static func drawText(_ s: String, at p: CGPoint, font: CTFont, color: CGColor, in ctx: CGContext) {
        let attr = NSAttributedString(string: s, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
        let line = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = p
        CTLineDraw(line, ctx)
    }

    /// A camera-like placeholder for snapshots of the bubble: a soft gradient with a simple face.
    public static func placeholderFace(size: Int = 512) -> CGImage {
        let s = CGFloat(size)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let grad = CGGradient(colorsSpace: cs, colors: [
            CGColor(srgbRed: 0.55, green: 0.62, blue: 0.70, alpha: 1), CGColor(srgbRed: 0.30, green: 0.34, blue: 0.40, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: .zero, options: [])
        // Shoulders, head, and an asymmetric hair part so mirroring is visible.
        ctx.setFillColor(CGColor(srgbRed: 0.18, green: 0.24, blue: 0.38, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: s * 0.12, y: -s * 0.35, width: s * 0.76, height: s * 0.6))
        ctx.setFillColor(CGColor(srgbRed: 0.93, green: 0.76, blue: 0.62, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: s * 0.33, y: s * 0.3, width: s * 0.34, height: s * 0.42))
        ctx.setFillColor(CGColor(srgbRed: 0.28, green: 0.18, blue: 0.12, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: s * 0.31, y: s * 0.58, width: s * 0.30, height: s * 0.17))
        ctx.setFillColor(CGColor(gray: 0.15, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: s * 0.42, y: s * 0.5, width: s * 0.03, height: s * 0.03))
        ctx.fillEllipse(in: CGRect(x: s * 0.55, y: s * 0.5, width: s * 0.03, height: s * 0.03))
        return ctx.makeImage()!
    }
}

// MARK: - Audio

/// Sine tones, as the writer wants them (48 kHz mono Float32 AVAudioPCMBuffer) and as
/// ScreenCaptureKit delivers them (CMSampleBuffer, any rate, host-time PTS) for AudioMixer.push.
public enum SyntheticAudio {
    public static func format(sampleRate: Double = 48_000, channels: AVAudioChannelCount = 1) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)!
    }

    /// `frames` samples of a sine starting at absolute sample `startSample` (phase-continuous across calls).
    public static func pcm(frames: Int, startSample: Int64, frequency: Double = 440, amplitude: Float = 0.25,
                           sampleRate: Double = 48_000, channels: AVAudioChannelCount = 1) -> AVAudioPCMBuffer {
        let buf = AVAudioPCMBuffer(pcmFormat: format(sampleRate: sampleRate, channels: channels), frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        for c in 0..<Int(channels) {
            let p = buf.floatChannelData![c]
            for i in 0..<frames {
                p[i] = amplitude * Float(sin(2 * .pi * frequency * Double(startSample + Int64(i)) / sampleRate))
            }
        }
        return buf
    }

    /// A constant-value buffer (for mixer sum/clamp tests).
    public static func constant(_ value: Float, frames: Int, sampleRate: Double = 48_000) -> AVAudioPCMBuffer {
        let buf = AVAudioPCMBuffer(pcmFormat: format(sampleRate: sampleRate), frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { buf.floatChannelData![0][i] = value }
        return buf
    }

    /// Wraps a PCM buffer in a CMSampleBuffer with presentation time `pts` (host clock in the app).
    public static func sampleBuffer(_ pcm: AVAudioPCMBuffer, pts: CMTime) -> CMSampleBuffer {
        var asbd = pcm.format.streamDescription.pointee
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(pcm.format.sampleRate)),
                                        presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
                             refcon: nil, formatDescription: fmt, sampleCount: CMItemCount(pcm.frameLength),
                             sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
                             sampleSizeArray: nil, sampleBufferOut: &sb)
        let rc = CMSampleBufferSetDataBufferFromAudioBufferList(sb!, blockBufferAllocator: kCFAllocatorDefault,
                                                                blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
                                                                bufferList: pcm.audioBufferList)
        precondition(rc == noErr, "CMSampleBufferSetDataBufferFromAudioBufferList: \(rc)")
        return sb!
    }

    /// A sine chunk as SCK would send it: `frames` samples at `sampleRate`, PTS = startSample / rate (+ `origin`).
    public static func sineSampleBuffer(frames: Int, startSample: Int64, sampleRate: Double = 48_000, frequency: Double = 440,
                                        amplitude: Float = 0.25, origin: CMTime = .zero) -> CMSampleBuffer {
        let pcm = pcm(frames: frames, startSample: startSample, frequency: frequency, amplitude: amplitude, sampleRate: sampleRate)
        let pts = CMTimeAdd(origin, CMTime(value: startSample, timescale: CMTimeScale(sampleRate)))
        return sampleBuffer(pcm, pts: pts)
    }

    public static func constantSampleBuffer(_ value: Float, frames: Int, startSample: Int64, sampleRate: Double = 48_000,
                                            origin: CMTime = .zero) -> CMSampleBuffer {
        let pts = CMTimeAdd(origin, CMTime(value: startSample, timescale: CMTimeScale(sampleRate)))
        return sampleBuffer(constant(value, frames: frames, sampleRate: sampleRate), pts: pts)
    }
}
