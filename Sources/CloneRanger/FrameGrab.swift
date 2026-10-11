import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// One still per video clip for the report.
enum FrameGrab {
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "mxf", "avi", "mts", "m2ts", "mkv", "mpg", "mpeg", "3gp", "insv"]
    /// RAW formats we list in the report but can't make a frame for yet (planned for a later version).
    static let rawExtensions: Set<String> = ["braw", "r3d", "crm", "ari", "nev"]

    static func isClip(_ path: String) -> Bool {
        let e = (path as NSString).pathExtension.lowercased()
        return videoExtensions.contains(e) || rawExtensions.contains(e)
    }

    struct Still: @unchecked Sendable {
        var image: CGImage?
        var duration: Double?
        var dimensions: String?
    }

    /// Frame about a tenth of the way in (past any slate or black). Falls back to the
    /// thumbnail Sony cameras write next to each clip (THMBNL / Thmbnl folders).
    static func still(for url: URL) async -> Still {
        var out = Still()
        let e = url.pathExtension.lowercased()
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
            let t = CMTime(seconds: min(10, (out.duration ?? 1) * 0.1), preferredTimescale: 600)
            out.image = await withTaskGroup(of: CGImage?.self) { group in
                group.addTask { try? await gen.image(at: t).image }
                group.addTask { try? await Task.sleep(for: .seconds(20)); return nil }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
        }
        if out.image == nil { out.image = sonyThumbnail(for: url) }
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
