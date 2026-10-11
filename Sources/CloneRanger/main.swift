import AppKit
import CRCore

// Build helper: CR_MAKE_ICON=<path.png> renders the 1024 px app icon and exits.
if let p = ProcessInfo.processInfo.environment["CR_MAKE_ICON"] {
    do { try Logo.iconPNG()!.write(to: URL(fileURLWithPath: p)) } catch { print(error); exit(1) }
    exit(0)
}
// Test only: CR_THROTTLE=<MB per second> slows reading so screenshots can catch a transfer mid-way.
if let mb = ProcessInfo.processInfo.environment["CR_THROTTLE"].flatMap(Double.init) {
    MultiCopy.throttle = mb * 1_000_000
}
if ProcessInfo.processInfo.environment["CR_TEST_CORRUPT"] != nil { Engine.corruptForTest = true }
if ProcessInfo.processInfo.environment["CR_TEST_CORRUPT_ALWAYS"] != nil { Engine.corruptForTest = true; Engine.corruptAlwaysForTest = true }
// Test only: CR_TEST_FRAMES=<folder> CR_SNAP_DIR=<dir> saves the report still for every clip, then exits.
if let dir = ProcessInfo.processInfo.environment["CR_TEST_FRAMES"] {
    let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CR_SNAP_DIR"] ?? NSTemporaryDirectory())
    let root = URL(fileURLWithPath: dir)
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        for item in Scanner.scan(root).items where item.kind == .file && FrameGrab.isClip(item.path) {
            let t0 = Date()
            let s = await FrameGrab.still(for: root.appendingPathComponent(item.path))
            let name = item.path.replacingOccurrences(of: "/", with: "_")
            print(String(format: "%@  %@  %@  %.1fs", item.path, s.image == nil ? "NO FRAME" : "frame", s.dimensions ?? "-", Date().timeIntervalSince(t0)))
            if let img = s.image { try? NSBitmapImageRep(cgImage: img).representation(using: .jpeg, properties: [:])?.write(to: out.appendingPathComponent(name + ".jpg")) }
        }
        done.signal()
    }
    done.wait()
    exit(0)
}
CloneRangerApp.main()
