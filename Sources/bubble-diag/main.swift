// Owner: QA track. bubble-diag: synthetic recordings, crash tests, file checks (docs/architecture.md §8).
// Nothing here touches the screen, camera or mic, except `record` (the one announced real run, §8.3).
import AppKit
import AVFoundation
import BubbleCore
import BubbleTesting
import CoreMedia
import Foundation

let usage = """
usage:
  bubble-diag synthetic <out.mp4> [--seconds N] [--size WxH] [--static-gaps] [--no-audio]
                                  [--pause AT:FOR]... [--crash-after S] [--fast] [--progress]
      Writes N s (default 10) of synthetic screen + sine audio through FramePump + RecordingWriter.
      Paced in real time unless --fast. --static-gaps: still-screen spans (the §6 writer bug).
      --pause AT:FOR: pause at AT s of video for FOR s. --crash-after S: abort() after S s of
      writing (wall clock; file time with --fast). The file must stay playable.
  bubble-diag check <file.mp4> [--json] [--min-seconds S] [--expect-seconds S] [--tolerance T]
      Decodes every frame; prints duration, frames, tracks, gaps. Exit 1 if not playable, or
      shorter than --min-seconds, or not within --tolerance (0.1) of --expect-seconds.
  bubble-diag frame <file.mp4> --at S --out <frame.png>
      Writes the decoded frame at S seconds as a PNG (full size), e.g. for the designer.
  bubble-diag record <out.mp4> [--seconds N]
      The ONE real ScreenCaptureKit run (docs/architecture.md §8.3). Ask main first.
"""

func fail(_ msg: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

struct Args {
    var positional: [String] = []
    var options: [String: [String]] = [:]
    var flags: Set<String> = []
    init(_ argv: ArraySlice<String>, valued: Set<String>) {
        var it = argv.makeIterator()
        while let a = it.next() {
            if a.hasPrefix("--") {
                if valued.contains(a) {
                    guard let v = it.next() else { fail("\(a) needs a value\n\n\(usage)") }
                    options[a, default: []].append(v)
                } else { flags.insert(a) }
            } else { positional.append(a) }
        }
    }
    func double(_ k: String) -> Double? {
        guard let s = options[k]?.last else { return nil }
        guard let d = Double(s) else { fail("\(k): not a number: \(s)") }
        return d
    }
}

// MARK: - synthetic

final class Failures: @unchecked Sendable { var first: String?; var appended = 0 }

func synthetic(_ args: Args) async {
    guard let out = args.positional.first else { fail(usage) }
    let url = URL(fileURLWithPath: out)
    let seconds = args.double("--seconds") ?? 10
    var w = 1280, h = 800
    if let size = args.options["--size"]?.last {
        let parts = size.split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2 else { fail("--size WxH") }
        w = parts[0]; h = parts[1]
    }
    let audio = !args.flags.contains("--no-audio")
    let realTime = !args.flags.contains("--fast")
    let crashAfter = args.double("--crash-after")
    let progress = args.flags.contains("--progress")
    // Still-screen spans: 2.5 s every 6 s, from 2 s on (they cross fragment boundaries).
    let staticGaps = args.flags.contains("--static-gaps")
    func isStatic(_ t: Double) -> Bool { staticGaps && t >= 2 && (t - 2).truncatingRemainder(dividingBy: 6) < 2.5 }
    var pausesLeft: [(at: Double, length: Double)] = (args.options["--pause"] ?? []).map {
        let p = $0.split(separator: ":").compactMap { Double($0) }
        guard p.count == 2 else { fail("--pause AT:FOR (seconds of video, seconds paused)") }
        return (p[0], p[1])
    }.sorted { $0.at < $1.at }

    try? FileManager.default.removeItem(at: url)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let video = VideoSettings.forDisplay(pointSize: CGSize(width: w, height: h), scale: 1)
    let writer: RecordingWriter
    do { writer = try RecordingWriter(url: url, video: video, audio: audio ? AudioSettings() : nil, realTime: realTime) }
    catch { fail("writer: \(error)", code: 1) }

    let failures = Failures()
    let pump = FramePump(fps: video.fps) { pb, t in
        do { try writer.appendVideo(pb, at: t); failures.appended += 1 }
        catch { if failures.first == nil { failures.first = "video at \(t.seconds): \(error)" } }
    }
    var frames: [CVPixelBuffer] = []
    for i in 0..<60 { frames.append(SyntheticFrames.frame(width: video.width, height: video.height, index: i, label: "bubble-diag")) }

    // A synthetic host clock ticks at fps; Timeline turns it into file time (pauses cut), like the app.
    let fps = Double(video.fps)
    let hostZero = CMTime(seconds: 1000, preferredTimescale: 600_000)
    func host(_ tick: Int) -> CMTime { CMTimeAdd(hostZero, CMTime(value: CMTimeValue(tick) * 20_000, timescale: 600_000)) }
    var timeline = Timeline()
    timeline.start(at: host(0))
    var audioSample: Int64 = 0
    var lastFileTime = CMTime.zero
    var resumeAtTick: Int?
    let wallStart = Date()
    var tick = 0
    while true {
        let h = host(tick)
        let fileT = timeline.elapsed(atHost: h)
        if let r = resumeAtTick, tick >= r { timeline.resume(at: h); resumeAtTick = nil }
        if resumeAtTick == nil && fileT >= seconds - 1e-9 { break }
        if realTime {
            let wait = Double(tick) / fps - Date().timeIntervalSince(wallStart)
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
        }
        if resumeAtTick == nil, let p = pausesLeft.first, fileT >= p.at - 1e-9 {
            timeline.pause(at: h); resumeAtTick = tick + Int((p.length * fps).rounded()); pausesLeft.removeFirst()
        }
        if !isStatic(fileT) { pump.submit(frames[tick % frames.count]) }
        if let ft = timeline.fileTime(forHost: h) {
            pump.tick(at: ft)
            lastFileTime = ft
            if audio {
                let target = Int64(((ft.seconds + 1 / fps) * 48_000).rounded())
                let n = Int(target - audioSample)
                if n > 0 {
                    do { try writer.appendAudio(SyntheticAudio.pcm(frames: n, startSample: audioSample), at: CMTime(value: audioSample, timescale: 48_000)) }
                    catch { if failures.first == nil { failures.first = "audio at \(ft.seconds): \(error)" } }
                    audioSample = target
                }
            }
        }
        if let first = failures.first { fail("append failed: \(first)", code: 1) }
        if let c = crashAfter, (realTime && Date().timeIntervalSince(wallStart) >= c) || (!realTime && fileT >= c) {
            print(String(format: "crashing on purpose: %.2f s wall, %.2f s of video, %d frames", Date().timeIntervalSince(wallStart), fileT, failures.appended))
            fflush(stdout)
            abort()
        }
        if progress && tick % Int(fps) == 0 { print(String(format: "%.0f s", fileT)); fflush(stdout) }
        tick += 1
    }
    let stop = CMTimeAdd(lastFileTime, CMTime(value: 1, timescale: CMTimeScale(video.fps)))
    do { try await writer.finish(at: stop) } catch { fail("finish: \(error)", code: 1) }
    print(String(format: "wrote %@: %.3f s, %d frames, %.1f MB, in %.1f s", url.path, stop.seconds, failures.appended,
                 Double(writer.bytesWritten) / 1e6, Date().timeIntervalSince(wallStart)))
}

// MARK: - check

func check(_ args: Args) async {
    guard let path = args.positional.first else { fail(usage) }
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path) else { fail("no such file: \(path)", code: 1) }
    let r = await MediaProbe.inspect(url)
    if args.flags.contains("--json") {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(data: try! enc.encode(r), encoding: .utf8)!)
    } else {
        print(r)
    }
    var ok = r.playable && r.decodedFrames > 0 && r.errors.isEmpty
    if let min = args.double("--min-seconds"), r.decodedSeconds < min {
        print(String(format: "FAIL: %.3f s decodable, wanted at least %.3f s", r.decodedSeconds, min)); ok = false
    }
    if let exp = args.double("--expect-seconds") {
        let tol = args.double("--tolerance") ?? 0.1
        if abs(r.duration - exp) > tol { print(String(format: "FAIL: duration %.3f s, wanted %.3f ± %.2f s", r.duration, exp, tol)); ok = false }
    }
    exit(ok ? 0 : 1)
}

// MARK: - frame

func frame(_ args: Args) async {
    guard let path = args.positional.first, let out = args.options["--out"]?.last else { fail(usage) }
    let at = args.double("--at") ?? 0
    guard let pb = try? await MediaProbe.frame(of: URL(fileURLWithPath: path), at: at) else { fail("no frame at \(at) s in \(path)", code: 1) }
    let rep = NSBitmapImageRep(ciImage: CIImage(cvPixelBuffer: pb))
    guard let png = rep.representation(using: .png, properties: [:]) else { fail("png encoding failed", code: 1) }
    do { try png.write(to: URL(fileURLWithPath: out)) } catch { fail("write \(out): \(error)", code: 1) }
    print("wrote \(out): \(CVPixelBufferGetWidth(pb))×\(CVPixelBufferGetHeight(pb)) at \(at) s")
}

// MARK: - record (the one real run)

// The one real ScreenCaptureKit run (docs/architecture.md §8.3), modeled on spikes/sck-record:
// a red round "bubble" panel (must be IN the video) and a blue "toolbar" panel (must be OUT), a
// real LiveRecorder take of N s (moving dot for N-3 s, then a still screen until Stop), then checks.
// Never part of check.sh: it records the real screen (and the mic if Bubble's terminal has access).
@MainActor
final class RecordRun {
    let out: URL
    let seconds: Double
    var results: [(Bool, String)] = []
    init(out: URL, seconds: Double) { self.out = out; self.seconds = seconds }

    func check(_ ok: Bool, _ what: String) {
        results.append((ok, what))
        print("\(ok ? "PASS" : "FAIL")  \(what)"); fflush(stdout)
    }

    func panel(_ rect: NSRect, color: NSColor, round: Bool) -> NSPanel {
        let p = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let v = NSView(frame: NSRect(origin: .zero, size: rect.size))
        v.wantsLayer = true
        v.layer!.backgroundColor = color.cgColor
        if round { v.layer!.cornerRadius = rect.width / 2 }
        p.contentView = v
        p.orderFrontRegardless()
        return p
    }

    func run() async -> Int32 {
        guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID() }) ?? NSScreen.main else {
            print("FAIL  no main display"); return 1
        }
        let displayID = CGMainDisplayID()
        let f = screen.frame
        // Bubble 180 pt, bottom-left 24 pt; toolbar 220×36 pt to its right.
        let bubbleRect = NSRect(x: f.minX + 24, y: f.minY + 24, width: 180, height: 180)
        let toolbarRect = NSRect(x: bubbleRect.maxX + 16, y: f.minY + 24, width: 220, height: 36)
        let bubble = panel(bubbleRect, color: .systemRed, round: true)
        let toolbar = panel(toolbarRect, color: .systemBlue, round: false)
        // A small white dot circling inside the bubble's rim: the screen changes (real frames) while
        // the bubble's center stays red.
        let dot = CALayer()
        dot.backgroundColor = NSColor.white.cgColor
        dot.frame = CGRect(x: 0, y: 0, width: 16, height: 16); dot.cornerRadius = 8
        bubble.contentView!.layer!.addSublayer(dot)
        try? await Task.sleep(for: .milliseconds(300))   // let the window server show them

        let micAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let mic = micAuthorized ? AVCaptureDevice.default(for: .audio)?.uniqueID : nil
        print("record: display \(displayID) \(Int(f.width))×\(Int(f.height)) pt @\(screen.backingScaleFactor)x, mic: \(mic ?? "none (not authorized for this process)"), \(seconds) s")
        let folder = out.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let options = RecordingOptions(displayID: displayID, bubbleWindowID: CGWindowID(bubble.windowNumber), microphoneID: mic,
                                       captureComputerSound: false, showClicks: true, folder: folder)

        // 1. The take.
        let recorder = LiveRecorder()
        var events: [RecorderEvent] = []
        recorder.onEvent = { events.append($0) }
        let url: URL
        do { url = try await recorder.start(options) } catch {
            check(false, "start: \(error)"); bubble.orderOut(nil); toolbar.orderOut(nil); return 1
        }
        check(true, "start returned \(url.lastPathComponent)")
        let t0 = Date()
        while Date().timeIntervalSince(t0) < seconds - 3 {
            let a = Date().timeIntervalSince(t0) * 2 * .pi / 2
            CATransaction.begin(); CATransaction.setDisableActions(true)
            dot.position = CGPoint(x: 90 + 70 * cos(a), y: 90 + 70 * sin(a))
            CATransaction.commit()
            try? await Task.sleep(for: .milliseconds(33))
        }
        try? await Task.sleep(for: .seconds(max(0, seconds - Date().timeIntervalSince(t0))))   // still screen until Stop
        let result = await recorder.stop()
        let wall = Date().timeIntervalSince(t0)
        check(result.reason == .user, "stopped by the user, reason \(result.reason)")
        check(!events.contains { if case .stoppedOnItsOwn = $0 { true } else { false } }, "no stop on its own (no -16341)")

        // 2. The file.
        let r = await MediaProbe.inspect(result.url)
        print("file: \(r)")
        check(r.playable && r.errors.isEmpty, "playable, every frame decodes")
        check(abs(r.duration - seconds) <= 0.25, String(format: "duration %.3f s for a %.1f s take (wall %.2f s, start→stop)", r.duration, seconds, wall))
        check(abs(result.duration - r.duration) <= 0.1, String(format: "RecordingResult.duration %.3f s matches the file", result.duration))
        let fps = Double(r.decodedFrames) / max(0.001, r.decodedSeconds)
        check(abs(fps - 30) < 0.6 && r.maxFrameGap < 0.05, String(format: "constant 30 fps: %.2f fps, max gap %.3f s", fps, r.maxFrameGap))
        let expectW = VideoSettings.forDisplay(pointSize: f.size, scale: screen.backingScaleFactor)
        check(r.width == expectW.width && r.height == expectW.height, "size \(r.width)×\(r.height), expected \(expectW.width)×\(expectW.height)")
        check(abs(r.duration - r.decodedSeconds) < 0.1, String(format: "the still last 3 s are in the file (decoded to %.3f s)", r.decodedSeconds))
        if mic != nil {
            check(r.audioTracks == 1 && abs(r.audioSeconds - r.duration) < 0.15, String(format: "mic audio track, %.3f s", r.audioSeconds))
        } else {
            print("SKIP  mic: this process has no microphone permission")
        }

        // 3. Bubble IN, toolbar OUT: pixels of a frame from the middle.
        if let pb = try? await MediaProbe.frame(of: result.url, at: r.duration / 2) {
            let sx = Double(CVPixelBufferGetWidth(pb)) / f.width, sy = Double(CVPixelBufferGetHeight(pb)) / f.height
            func px(_ p: NSPoint) -> (r: Int, g: Int, b: Int) {
                let x = Int((p.x - f.minX) * sx), y = Int((f.maxY - p.y) * sy)
                CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
                let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
                let o = y * CVPixelBufferGetBytesPerRow(pb) + x * 4
                return (Int(base[o + 2]), Int(base[o + 1]), Int(base[o]))
            }
            let b = px(NSPoint(x: bubbleRect.midX, y: bubbleRect.midY))
            let t = px(NSPoint(x: toolbarRect.midX, y: toolbarRect.midY))
            check(b.r > 180 && b.g < 110 && b.b < 110, "bubble IN the video: center pixel rgb(\(b.r),\(b.g),\(b.b)) is red")
            check(!(t.b > 180 && t.r < 110 && t.g < 160), "toolbar OUT of the video: center pixel rgb(\(t.r),\(t.g),\(t.b)) is not blue")
        } else {
            check(false, "could not decode a frame from the middle")
        }
        // Keep the file under the asked name.
        if result.url.standardizedFileURL != out.standardizedFileURL {
            try? FileManager.default.removeItem(at: out)
            if (try? FileManager.default.moveItem(at: result.url, to: out)) != nil { print("file moved to \(out.path)") }
        }

        // 4. A transparent bubble (alpha 0, camera not live yet) must still be found.
        bubble.alphaValue = 0
        try? await Task.sleep(for: .milliseconds(200))
        let second = LiveRecorder()
        do {
            let u2 = try await second.start(options)
            try? await Task.sleep(for: .seconds(2))
            let r2 = await second.stop()
            check(r2.reason == .user, "start with the bubble at alpha 0: found, 2 s recorded")
            try? FileManager.default.removeItem(at: u2)
        } catch {
            check(false, "start with the bubble at alpha 0: \(error)")
        }
        bubble.orderOut(nil); toolbar.orderOut(nil)

        let failed = results.filter { !$0.0 }.count
        print(failed == 0 ? "ALL PASS (\(results.count) checks)" : "\(failed) FAILED of \(results.count) checks")
        return failed == 0 ? 0 : 1
    }
}

@MainActor
func record(_ args: Args) -> Never {
    guard let out = args.positional.first else { fail(usage) }
    let seconds = args.double("--seconds") ?? 10
    guard seconds >= 5 else { fail("--seconds: at least 5 (the last 3 s are a still screen)") }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let run = RecordRun(out: URL(fileURLWithPath: out), seconds: seconds)
    Task { @MainActor in exit(await run.run()) }
    app.run()
    exit(1)
}

// MARK: - main

let argv = CommandLine.arguments.dropFirst()
guard let command = argv.first else { fail(usage) }
let args = Args(argv.dropFirst(), valued: ["--seconds", "--size", "--crash-after", "--pause", "--min-seconds", "--expect-seconds", "--tolerance", "--at", "--out"])
switch command {
case "synthetic": await synthetic(args)
case "check": await check(args)
case "frame": await frame(args)
case "record": await record(args)
case "-h", "--help", "help": print(usage)
default: fail("unknown command \(command)\n\n\(usage)")
}
