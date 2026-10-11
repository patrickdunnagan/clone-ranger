import CRCore
import Foundation

// Headless transfer for testing: cr-cli <source> <destination parent>...
// Prints timing and any problems; exit code 1 if anything failed.
let args = Array(CommandLine.arguments.dropFirst())
// cr-cli --hash <file> <depth>: timing of the verify read.
// cr-cli --write <file> <GB> <chunkMB> [cached]: raw write speed of a drive (file is removed after).
if args.first == "--write", args.count >= 4 {
    let chunk = Int(args[3])! << 20, total = Int64(Double(args[2])! * 1e9)
    let fd = open(args[1], O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    if args.count < 5 { _ = fcntl(fd, F_NOCACHE, 1) }
    let buf = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 4096)
    arc4random_buf(buf, chunk)
    let t = Date()
    var done: Int64 = 0
    while done < total { done += Int64(write(fd, buf, chunk)) }
    fsync(fd); close(fd)
    let secs = Date().timeIntervalSince(t)
    unlink(args[1])
    print(String(format: "write %@ chunk %@MB %@: %.0f MB/s", args[2], args[3], args.count < 5 ? "nocache" : "cached", Double(done) / secs / 1e6))
    exit(0)
}
if args.first == "--resident", args.count >= 2 {
    for f in args.dropFirst() { print(String(format: "%.4f  %@", MultiCopy.residentFraction(f), f)) }
    exit(0)
}
if args.first == "--hash", args.count >= 3 {
    let t = Date()
    let h = try MultiCopy.hashFile(args[1], depth: Int(args[2]) ?? 1, chunk: (args.count > 3 ? Int(args[3])! : 8) << 20, cached: args.count > 4)
    let size = (try FileManager.default.attributesOfItem(atPath: args[1])[.size] as! NSNumber).doubleValue
    let secs = Date().timeIntervalSince(t)
    print(String(format: "%@  depth %@ chunk %@MB  %.0f MB/s", XXHash64.hex(h), args[2], args.count > 3 ? args[3] : "8", size / secs / 1e6))
    exit(0)
}
guard args.count >= 2 else {
    print("usage: cr-cli <source> <destination parent>...")
    exit(2)
}
let env = ProcessInfo.processInfo.environment
if env["CR_SOURCE_NOCACHE"] != nil { MultiCopy.sourceCached = false }
if let mb = env["CR_CHUNK_MB"].flatMap(Int.init) { MultiCopy.copyChunk = mb << 20 }
if env["CR_DEST_CACHED"] != nil { MultiCopy.destCached = true }
let source = URL(fileURLWithPath: args[0])
var taken: [String: Set<String>] = [:]
let targets = args.dropFirst().map { p -> String in
    let parent = URL(fileURLWithPath: p)
    let name = Plan.targetName(for: source, in: parent, also: taken[parent.path] ?? [])
    taken[parent.path, default: []].insert(name.lowercased())
    return FS.join(p, name)
}
let progress = TransferProgress(destinations: targets.count)
let t0 = Date()
var stageTimes: [String] = []
if env["CR_TEST_CORRUPT"] != nil { Engine.corruptForTest = true }
let out = Engine.run(source: args[0], targets: targets, control: JobControl(), progress: progress) { s in
    stageTimes.append("\(s) at \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
}
let s = out.scan
let copy = out.copyFinished.timeIntervalSince(out.copyStarted)
let verify = out.verifyFinished.timeIntervalSince(out.copyFinished)
print("files \(s.files)  bytes \(s.bytes)  skipped \(s.skipped)")
print(stageTimes.joined(separator: "  |  "))
print(String(format: "copy %.2fs (%.0f MB/s read)  verify %.2fs", copy, Double(s.bytes) / max(copy, 0.001) / 1e6, verify))
for t in targets { print("→ \(t)") }
for (d, p) in out.destinationProblems.enumerated() where p != nil { print("DEST \(d) PROBLEM: \(p!)") }
var bad = 0
for r in out.results where r.errors.contains(where: { $0 != nil }) {
    bad += 1
    if bad <= 20 { print("FAIL \(r.item.path): \(r.errors.compactMap { $0 }.joined(separator: " / "))") }
}
for r in out.results where r.retried.contains(true) { print("RE-COPIED: \(r.item.path) first: \(r.firstError.compactMap { $0 }.joined()) now: \(r.errors.map { $0 ?? "OK" }.joined(separator: ", "))") }
print(bad == 0 && s.problems.isEmpty ? "ALL VERIFIED" : "\(bad) failed")
exit(bad == 0 ? 0 : 1)
