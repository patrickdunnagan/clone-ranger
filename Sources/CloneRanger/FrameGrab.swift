import AVFoundation
import BRAWBridge
import R3DBridge
import CoreGraphics
import Foundation
import ImageIO

/// One still per video clip for the report.
enum FrameGrab {
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "mxf", "avi", "mts", "m2ts", "mkv", "mpg", "mpeg", "3gp", "insv"]
    /// RAW formats we list in the report but can't make a frame for yet (planned for a later version).
    static let rawExtensions: Set<String> = ["braw", "r3d", "crm", "ari", "nev"]

    /// Folder holding BlackmagicRawAPI.framework: inside the app, else the installed SDK (development).
    static let brawLibDir: String? = {
        let fm = FileManager.default
        let candidates = [Bundle.main.privateFrameworksPath,
                          "/Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac/Libraries"].compactMap { $0 }
        return candidates.first { fm.fileExists(atPath: $0 + "/BlackmagicRawAPI.framework") }
    }()

    /// Folder holding REDR3D.dylib: inside the app, else the vendored SDK (development).
    static let r3dLibDir: String? = {
        let fm = FileManager.default
        let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Vendor/RED/Redistributable").path
        let candidates = [ProcessInfo.processInfo.environment["CR_R3D_LIB"], Bundle.main.privateFrameworksPath, dev].compactMap { $0 }
        return candidates.first { fm.fileExists(atPath: $0 + "/REDR3D.dylib") }
    }()

    /// Formats this build can make a frame for (RAW only when its library is present).
    static func canPreview(_ ext: String) -> Bool {
        videoExtensions.contains(ext) || (ext == "braw" && brawLibDir != nil) || (ext == "r3d" && r3dLibDir != nil)
    }

    static func r3dStill(_ path: String, at fraction: Double = 0.1) -> Still {
        var out = Still()
        guard let lib = r3dLibDir else { return out }
        var s = R3DStill()
        if r3d_grab(lib, path, fraction, 480, &s) == 1, let px = s.bgra {
            defer { r3d_free(&s) }
            let w = Int(s.width), h = Int(s.height)
            let data = Data(bytes: px, count: w * h * 4)
            if let provider = CGDataProvider(data: data as CFData) {
                out.image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                    space: CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            }
        }
        if s.clipWidth > 0 { out.dimensions = "\(s.clipWidth)×\(s.clipHeight)" }
        if s.duration > 0 { out.duration = s.duration }
        return out
    }

    static func brawStill(_ path: String, at fraction: Double = 0.1) -> Still {
        var out = Still()
        guard let lib = brawLibDir else { return out }
        var s = BRAWStill()
        if braw_grab(lib, path, fraction, 480, &s) == 1, let px = s.rgba {
            defer { braw_free(&s) }
            let w = Int(s.width), h = Int(s.height)
            let data = Data(bytes: px, count: w * h * 4)
            if let provider = CGDataProvider(data: data as CFData) {
                out.image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                    space: CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            }
        }
        if s.clipWidth > 0 { out.dimensions = "\(s.clipWidth)×\(s.clipHeight)" }
        if s.duration > 0 { out.duration = s.duration }
        return out
    }

    static func isClip(_ path: String) -> Bool {
        let e = (path as NSString).pathExtension.lowercased()
        return videoExtensions.contains(e) || rawExtensions.contains(e)
    }

    struct Still: @unchecked Sendable {
        var image: CGImage?                   // the only frame, or the one near the start
        var middle: CGImage?                  // clips longer than `twoFrameLength`: the middle frame
        var times: [Double] = []              // seconds into the clip of each frame shown
        var duration: Double?
        var dimensions: String?
    }

    /// Clips longer than this get two frames: near the start and the middle.
    static let twoFrameLength: Double = 30
    /// "Near the start": far enough in to miss black frames and slates.
    static let startOffset: Double = 2

    /// RAW clips: one decode to learn the length, then the start and middle frames if it's long.
    static func rawStill(_ path: String, braw: Bool) -> Still {
        let grab = { (f: Double) in braw ? brawStill(path, at: f) : r3dStill(path, at: f) }
        var out = grab(0.1)
        guard let d = out.duration, d > 0 else { return out }
        out.times = [d * 0.1]
        if d > twoFrameLength {
            let start = grab(startOffset / d), mid = grab(0.5)
            if start.image != nil { out.image = start.image; out.times = [startOffset] }
            if mid.image != nil { out.middle = mid.image; out.times.append(d / 2) }
        }
        return out
    }

    /// Frame about a tenth of the way in (past any slate or black); for clips over 30 s, one ~2 s in
    /// and one at the middle. Falls back to the
    /// thumbnail Sony cameras write next to each clip (THMBNL / Thmbnl folders).
    static func still(for url: URL) async -> Still {
        var out = Still()
        let e = url.pathExtension.lowercased()
        if e == "braw" || e == "r3d" {
            // Decoding is blocking C++; give it a worker thread and the same 20 s limit as video.
            return await withTaskGroup(of: Still?.self) { group in
                group.addTask { await Task.detached { rawStill(url.path, braw: e == "braw") }.value }
                group.addTask { try? await Task.sleep(for: .seconds(20)); return nil }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first ?? Still()
            }
        }
        if videoExtensions.contains(e) {
            let asset = AVURLAsset(url: url)
            if let d = try? await asset.load(.duration), d.isNumeric, d.seconds > 0 { out.duration = d.seconds }
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize) {
                out.dimensions = "\(Int(abs(size.width)))×\(Int(abs(size.height)))"
            }
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 480, height: 270)
            gen.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
            func frame(_ seconds: Double) async -> CGImage? {
                let t = CMTime(seconds: seconds, preferredTimescale: 600)
                return await withTaskGroup(of: CGImage?.self) { group in
                    group.addTask { try? await gen.image(at: t).image }
                    group.addTask { try? await Task.sleep(for: .seconds(20)); return nil }
                    let first = await group.next() ?? nil
                    group.cancelAll()
                    return first
                }
            }
            let d = out.duration ?? 1
            if d > twoFrameLength {
                out.image = await frame(startOffset)
                out.middle = await frame(d / 2)
                out.times = [startOffset, d / 2]
            } else {
                let t = min(10, d * 0.1)
                out.image = await frame(t)
                out.times = [t]
            }
        }
        // Formats the Mac can't open itself (Sony XAVC MXF and others): the small bundled FFmpeg.
        if out.image == nil, ffmpegPath != nil, videoExtensions.contains(e) {
            let f = await Task.detached { ffmpegStill(url.path) }.value
            if f.image != nil { return f }
            if out.duration == nil { out.duration = f.duration; out.dimensions = f.dimensions }
        }
        if out.image == nil { out.image = sonyThumbnail(for: url); out.middle = nil; out.times = [] }
        return out
    }

    /// The bundled FFmpeg (Contents/MacOS/ffmpeg-cr), or the vendored one when developing.
    static let ffmpegPath: String? = {
        let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Vendor/FFmpeg/ffmpeg-cr").path
        return [Bundle.main.path(forAuxiliaryExecutable: "ffmpeg-cr"), dev].compactMap { $0 }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// Runs FFmpeg with a time limit; returns (stdout, stderr).
    static func runFFmpeg(_ args: [String], timeout: Double = 20) -> (Data, String) {
        guard let ff = ffmpegPath else { return (Data(), "") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ff)
        p.arguments = ["-hide_banner", "-nostdin"] + args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        guard (try? p.run()) != nil else { return (Data(), "") }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        var data = Data(), errData = Data()
        let g = DispatchGroup()
        g.enter(); DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        data = out.fileHandleForReading.readDataToEndOfFile()
        g.wait()
        p.waitUntilExit()
        killer.cancel()
        return (data, String(decoding: errData, as: UTF8.self))
    }

    /// Length and size from FFmpeg's description of the file, then the same frames as any other clip.
    static func ffmpegStill(_ path: String) -> Still {
        var out = Still()
        let (_, info) = runFFmpeg(["-i", path], timeout: 10)
        if let r = info.range(of: #"Duration: (\d+):(\d+):(\d+(?:\.\d+)?)"#, options: .regularExpression) {
            let parts = info[r].dropFirst("Duration: ".count).split(separator: ":").compactMap { Double($0) }
            if parts.count == 3 { out.duration = parts[0] * 3600 + parts[1] * 60 + parts[2] }
        }
        if let line = info.split(separator: "\n").first(where: { $0.contains("Video:") }),
           let r = line.range(of: #" (\d{2,5})x(\d{2,5})"#, options: .regularExpression) {
            out.dimensions = line[r].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "x", with: "×")
        }
        func frame(_ t: Double) -> CGImage? {
            let (jpg, _) = runFFmpeg(["-v", "error", "-ss", String(format: "%.3f", t), "-i", path, "-frames:v", "1",
                                      "-vf", "scale=480:-2", "-q:v", "3", "-f", "image2pipe", "-c:v", "mjpeg", "-"])
            guard !jpg.isEmpty, let src = CGImageSourceCreateWithData(jpg as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        let d = out.duration ?? 1
        if d > twoFrameLength {
            out.image = frame(startOffset)
            out.middle = frame(d / 2)
            out.times = [startOffset, d / 2]
        } else {
            let t = min(10, d * 0.1)
            out.image = frame(t)
            out.times = [t]
        }
        return out
    }

    /// A001C003_261010.MP4 → ../THMBNL/A001C003_261010T01.JPG (case doesn't matter).
    static func sonyThumbnail(for url: URL) -> CGImage? {
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        let root = url.deletingLastPathComponent().deletingLastPathComponent()
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        for d in dirs where d.lastPathComponent.lowercased() == "thmbnl" {
            guard let files = try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil) else { continue }
            for f in files {
                let n = f.deletingPathExtension().lastPathComponent.lowercased()
                if (n == stem + "t01" || n == stem) && ["jpg", "jpeg"].contains(f.pathExtension.lowercased()),
                   let src = CGImageSourceCreateWithURL(f as CFURL, nil),
                   let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                    return img
                }
            }
        }
        return nil
    }
}
