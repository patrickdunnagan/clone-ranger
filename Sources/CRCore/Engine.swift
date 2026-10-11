import Foundation

/// Live counters a running transfer updates from worker threads; the UI reads a snapshot a few times a second.
public final class TransferProgress: @unchecked Sendable {
    private let lock = NSLock()
    public struct Snapshot: Sendable {
        public var read: Int64 = 0
        public var written: [Int64] = []
        public var verified: [Int64] = []
        public var filesCopied = 0
        public var filesVerified: [Int] = []
        public var current = ""
        public init() {}
    }
    private var s = Snapshot()
    public init(destinations: Int) {
        s.written = Array(repeating: 0, count: destinations)
        s.verified = Array(repeating: 0, count: destinations)
        s.filesVerified = Array(repeating: 0, count: destinations)
    }
    public var snapshot: Snapshot { lock.withLock { s } }
    func update(_ f: (inout Snapshot) -> Void) { lock.withLock { f(&s) } }
}

public enum Stage: Sendable { case scanning, copying, verifying, retrying(Int), writingReport, done }

/// Result for one file (or folder/link) across every destination.
public struct ItemResult: Sendable {
    public var item: SourceItem
    public var hash: String?            // source xxHash64, nil for folders/links/failed reads
    public var errors: [String?]        // per destination; nil = no problem
    public var verified: [Bool]         // per destination: read back and matched (links: created)
    public var retried: [Bool]          // per destination: failed the first time, copied again
    public var firstError: [String?]    // per destination: what went wrong the first time
}

public struct TransferOutcome: Sendable {
    public var scan: ScanResult
    public var results: [ItemResult]
    public var destinationProblems: [String?]   // a whole destination that couldn't be used
    public var canceled: Bool
    public var copyStarted: Date
    public var copyFinished: Date
    public var verifyFinished: Date
    /// Files that failed the first time but are fine now.
    public var recoveredCount: Int {
        results.filter { r in r.retried.contains(true) && !r.errors.contains { $0 != nil } }.count
    }
    public var failedCount: Int {
        results.filter { $0.errors.contains { $0 != nil } }.count + scan.problems.count
    }
}

public enum Engine {
    public static let bigFile: Int64 = 64 * 1024 * 1024
    /// Test only: change one byte of the first copied file on the first destination between the copy and
    /// the verify, to prove the verify catches it.
    nonisolated(unsafe) public static var corruptForTest = false

    /// Copies everything in `source` into each of `targets` (the new "CLIP" / "CLIP 2" folders, not yet
    /// created), then reads every destination back and compares checksums. The source is only ever read.
    /// `source` and `targets` are plain paths (see FS) so names are recreated byte for byte.
    public static func run(source: String, targets: [String], control: JobControl, progress: TransferProgress,
                           scanned: ScanResult? = nil,
                           stage: @escaping @Sendable (Stage) -> Void) -> TransferOutcome {
        let n = targets.count
        stage(.scanning)
        let scan = scanned ?? Scanner.scan(path: source)
        let parents = targets.map { URL(fileURLWithPath: ($0 as NSString).deletingLastPathComponent) }
        let local = parents.map { Plan.isLocal($0) }
        var destProblems = [String?](repeating: nil, count: n)

        // Room on each drive (destinations on the same drive share it).
        var need: [String: Int64] = [:]
        var vol: [String] = []
        for t in parents {
            let v = (try? t.resourceValues(forKeys: [.volumeURLKey]))?.volume?.path ?? t.path
            vol.append(v)
            need[v, default: 0] += scan.bytes
        }
        for d in 0..<n {
            if let free = Plan.freeSpace(parents[d]), free < need[vol[d]]! {
                destProblems[d] = "Not enough room: needs \(ByteCountFormatter.string(fromByteCount: need[vol[d]]!, countStyle: .file)), \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free"
            }
        }
        for d in 0..<n where destProblems[d] == nil {
            do { try FS.makeNewFolder(targets[d]) } catch {
                destProblems[d] = error.localizedDescription
            }
        }

        var results = scan.items.map { ItemResult(item: $0, hash: nil, errors: destProblems, verified: Array(repeating: false, count: n), retried: Array(repeating: false, count: n), firstError: Array(repeating: nil, count: n)) }
        let live = (0..<n).filter { destProblems[$0] == nil }
        let copyStarted = Date()
        stage(.copying)

        // Folders first (all of them, up front), then files.
        for (i, r) in results.enumerated() where r.item.kind == .folder {
            for d in live {
                do { try FS.makeFolders(FS.join(targets[d], r.item.path)) } catch {
                    results[i].errors[d] = error.localizedDescription
                }
            }
        }

        let files = results.indices.filter { results[$0].item.kind != .folder }
        let lock = NSLock()
        var next = 0
        let bigGate = DispatchSemaphore(value: 0)
        bigGate.signal()   // one big file at a time: cards and drives read best in one long run
        var corrupted = false

        /// Reads one copy back off its drive and compares it with the source checksum.
        func verifyOne(_ k: Int, _ d: Int, counting: Bool) {
            let url = FS.join(targets[d], scan.items[k].path)
            let expected = lock.withLock { results[k].hash }
            var err: String?
            do {
                // If none of the copy is in memory, a normal read must come off the drive, and its
                // read-ahead is far faster. Otherwise force every byte to come off the drive.
                let cached = MultiCopy.residentFraction(url) == 0
                let h = XXHash64.hex(try MultiCopy.hashFile(url, control: control, depth: cached ? 1 : 4, cached: cached) { b in
                    if counting { progress.update { $0.verified[d] += b } }
                })
                if h != expected { err = "Checksum didn't match: source \(expected ?? "?"), destination \(h)" }
            } catch CopyError.cancelled {
                err = CopyError.cancelled.localizedDescription
            } catch {
                err = error.localizedDescription
            }
            lock.withLock {
                results[k].errors[d] = err
                results[k].verified[d] = err == nil
            }
            if counting { progress.update { $0.filesVerified[d] += 1 } }
        }

        if !live.isEmpty {
            // Small files (stills, sidecars, XML) overlap to hide the per-file overhead.
            DispatchQueue.concurrentPerform(iterations: max(1, min(4, files.count))) { _ in
                while true {
                    let k: Int? = lock.withLock {
                        guard next < files.count, !control.cancelled else { return nil }
                        defer { next += 1 }
                        return files[next]
                    }
                    guard let k else { return }
                    let item = scan.items[k]
                    let src = FS.join(source, item.path)
                    let dests = live.filter { results[k].errors[$0] == nil }
                    if item.kind == .link {
                        for d in dests {
                            var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                            let len = readlink(src, &buf, Int(PATH_MAX))
                            if len >= 0, symlink(String(cString: buf), FS.join(targets[d], item.path)) == 0 {
                                lock.withLock { results[k].verified[d] = true }
                            } else {
                                let e = FS.errorText()
                                lock.withLock { results[k].errors[d] = "Couldn't copy link: \(e)" }
                            }
                        }
                        progress.update { $0.filesCopied += 1 }
                        continue
                    }
                    let big = item.size >= bigFile
                    if big { bigGate.wait() }
                    progress.update { $0.current = item.path }
                    let out = MultiCopy.copy(src, to: dests.map { FS.join(targets[$0], item.path) },
                                             local: dests.map { local[$0] }, control: control,
                                             read: { b in progress.update { $0.read += b } },
                                             wrote: { i, b in progress.update { $0.written[dests[i]] += b } })
                    if big { bigGate.signal() }
                    if corruptForTest, item.size > 2000, out.errors.allSatisfy({ $0 == nil }), out.sourceError == nil,
                       dests.first == 0, lock.withLock({ () -> Bool in defer { corrupted = true }; return !corrupted }) {
                        let fd = open(FS.join(targets[0], item.path), O_WRONLY)
                        var b: UInt8 = 0x5A
                        _ = pwrite(fd, &b, 1, 1000)
                        close(fd)
                    }
                    lock.withLock {
                        results[k].hash = out.hash.map(XXHash64.hex)
                        for (i, d) in dests.enumerated() {
                            results[k].errors[d] = out.sourceError ?? out.errors[i]
                        }
                    }
                    progress.update { $0.filesCopied += 1 }
                }
            }
        }
        let copyFinished = Date()

        // Stage 2: read every copy back off each destination (all destinations at once) and compare.
        if !control.cancelled {
            stage(.verifying)
            DispatchQueue.concurrentPerform(iterations: n) { d in
                guard destProblems[d] == nil else { return }
                let mine = files.filter { k in lock.withLock { results[k].errors[d] == nil && results[k].hash != nil } }
                var nextFile = 0
                let gate = DispatchSemaphore(value: 0)
                gate.signal()
                DispatchQueue.concurrentPerform(iterations: max(1, min(3, mine.count))) { _ in
                    while true {
                        let k: Int? = lock.withLock {
                            guard nextFile < mine.count, !control.cancelled else { return nil }
                            defer { nextFile += 1 }
                            return mine[nextFile]
                        }
                        guard let k else { return }
                        let big = scan.items[k].size >= bigFile
                        if big { gate.wait() }
                        verifyOne(k, d, counting: true)
                        if big { gate.signal() }
                    }
                }
            }
        }

        // Stage 3, only if something went wrong: copy just the failed files again from the source, to just
        // the destinations they failed on, and verify them again. Two more tries, a pause before each so a
        // network share can recover. The first problem is kept for the report.
        for attempt in 1...2 where !control.cancelled {
            let failed = files.filter { k in
                scan.items[k].kind == .file && live.contains { d in results[k].errors[d] != nil && !results[k].verified[d] }
            }
            if failed.isEmpty { break }
            stage(.retrying(failed.count))
            Thread.sleep(forTimeInterval: 2)
            for k in failed where !control.cancelled {
                let item = scan.items[k]
                let dests = live.filter { results[k].errors[$0] != nil && !results[k].verified[$0] }
                for d in dests where results[k].firstError[d] == nil { results[k].firstError[d] = results[k].errors[d] }
                let urls = dests.map { FS.join(targets[$0], item.path) }
                for u in urls { unlink(u) }   // our own bad copy from moments ago
                progress.update { $0.current = item.path }
                let out = MultiCopy.copy(FS.join(source, item.path), to: urls, local: dests.map { local[$0] },
                                         control: control, read: { _ in }, wrote: { _, _ in })
                let newHash = out.hash.map(XXHash64.hex)
                for (i, d) in dests.enumerated() {
                    results[k].retried[d] = true
                    if let e = out.sourceError ?? out.errors[i] {
                        results[k].errors[d] = "Copy attempt \(attempt + 1) failed: \(e)"
                    } else if results[k].hash != nil && newHash != results[k].hash {
                        // The source gave different data this time: the card or reader can't be trusted.
                        results[k].errors[d] = "The source read differently on attempt \(attempt + 1) (\(results[k].hash!) then \(newHash ?? "?")). The card or reader may be failing."
                    } else {
                        if results[k].hash == nil { results[k].hash = newHash }   // the first read never finished
                        verifyOne(k, d, counting: false)
                        if let e = results[k].errors[d] { results[k].errors[d] = "Attempt \(attempt + 1): \(e)" }
                    }
                }
            }
        }

        // Folder dates last (writing into a folder changes its date), deepest first.
        for r in results.reversed() where r.item.kind == .folder {
            guard let st = FS.lstatInfo(FS.join(source, r.item.path)) else { continue }
            for d in live where r.errors[d] == nil {
                FS.setDates(FS.join(targets[d], r.item.path), modified: st.st_mtimespec, created: st.st_birthtimespec)
            }
        }

        // Nothing counts as done unless it was read back and matched.
        for k in files {
            for d in 0..<n where results[k].errors[d] == nil && !results[k].verified[d] {
                results[k].errors[d] = control.cancelled ? "Canceled before it was copied and verified" : "Not verified"
            }
        }

        return TransferOutcome(scan: scan, results: results, destinationProblems: destProblems,
                               canceled: control.cancelled, copyStarted: copyStarted,
                               copyFinished: copyFinished, verifyFinished: Date())
    }
}
