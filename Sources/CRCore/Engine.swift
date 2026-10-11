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
        public var recheckSourceDone: Int64 = 0    // after an unplug: bytes re-read from the source
        public var recheckSourceTotal: Int64 = 0
        public var recheckDestDone: Int64 = 0      // …and read back from the destinations
        public var recheckDestTotal: Int64 = 0
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

public enum Stage: Sendable { case scanning, copying, verifying, retrying(Int), rechecking, writingReport, done }

/// Result for one file (or folder/link) across every destination.
public struct ItemResult: Sendable, Codable {
    public var item: SourceItem
    public var hash: String?            // source xxHash64, nil for folders/links/unread files
    public var errors: [String?]        // per destination; nil = no problem (yet)
    public var copied: [Bool]           // per destination: written in full and in place
    public var verified: [Bool]         // per destination: read back and matched (links: created)
    public var retried: [Bool]          // per destination: failed the first time, copied again
    public var firstError: [String?]    // per destination: what went wrong the first time
    public var unverified: [[String]]   // per destination: where copies that failed their verify were moved
}

public enum ResumeMode: String, Sendable, Codable {
    case full    // re-read every already-copied file from the source
    case quick   // names/sizes/dates, start and end of every file, last two files in full
}

/// Something that happened along the way, for the report ("14:02 A001 was unplugged…").
public struct TransferEvent: Sendable, Codable {
    public var date: Date
    public var text: String
    public var bad: Bool
}

public struct TransferOutcome: Sendable {
    public var scan: ScanResult
    public var results: [ItemResult]
    public var destinationProblems: [String?]   // a whole destination that couldn't be used
    public var canceled: Bool
    public var sourceGone: Bool                  // the source disappeared; waiting for it to come back
    public var destGone: [Bool]                  // a destination disappeared; waiting for it to come back
    public var fatal: String?                    // stopped for good (e.g. the card changed while unplugged)
    public var events: [TransferEvent]
    public var copyStarted: Date
    public var copyFinished: Date
    public var verifyFinished: Date

    public var interrupted: Bool { fatal == nil && !canceled && (sourceGone || destGone.contains(true)) }
    /// Files that failed the first time but are fine now.
    public var recoveredCount: Int {
        results.filter { r in r.retried.contains(true) && !r.errors.contains { $0 != nil } }.count
    }
    public var failedCount: Int {
        results.filter { $0.errors.contains { $0 != nil } }.count + scan.problems.count
    }
    /// Bytes already copied (at least to one destination) when the transfer stopped.
    public var copiedBytes: Int64 {
        results.reduce(0) { $0 + ($1.item.kind == .file && $1.copied.contains(true) ? $1.item.size : 0) }
    }
}

/// Everything needed to pick a transfer back up, even after Clone Ranger quits or crashes.
public struct JobState: Codable, Sendable {
    public var source: String
    public var sourceVolumeUUID: String?
    public var targets: [String]
    public var scan: ScanResult
    public var results: [ItemResult]
    public var destinationProblems: [String?]
    public var copyOrder: [Int]
    public var events: [TransferEvent]
    public var copyStarted: Date
    public var sourceLost: Bool          // the source went away at some point, so it must be re-checked
    public var sourceName: String?
    public var targetVolumes: [String]?  // drive names, remembered while they were plugged in
}

public enum Engine {
    public static let bigFile: Int64 = 64 * 1024 * 1024
    /// Test only: change one byte of the first copied file on the first destination between the copy and
    /// the verify, to prove the verify catches it.
    nonisolated(unsafe) public static var corruptForTest = false
    /// Test only: also damage every second and third copy, so the file ends up failed.
    nonisolated(unsafe) public static var corruptAlwaysForTest = false

    /// "Day 2/CLIP" → "Day 2/CLIP Unverified": copies that failed their verify are moved here, under the
    /// same folders, so the real copy only ever holds verified files.
    public static func unverifiedFolder(forTarget t: String) -> String {
        FS.join((t as NSString).deletingLastPathComponent, (t as NSString).lastPathComponent + " Unverified")
    }

    public static func volumeUUID(_ path: String) -> String? {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
    }

    /// One-shot transfer (the command-line tool uses this).
    public static func run(source: String, targets: [String], control: JobControl, progress: TransferProgress,
                           stage: @escaping @Sendable (Stage) -> Void) -> TransferOutcome {
        TransferJob(source: source, targets: targets, control: control, progress: progress, stage: stage).start()
    }
}

/// One transfer: copy everything from the source into each target, read every copy back, copy failures
/// again. If the source or a destination disappears it stops and can be resumed later.
/// `source` and `targets` are plain paths (see FS) so names are recreated byte for byte.
public final class TransferJob: @unchecked Sendable {
    public let source: String
    public let targets: [String]
    public var control: JobControl
    public var progress: TransferProgress
    public var stage: @Sendable (Stage) -> Void

    private let lock = NSLock()
    private var scan = ScanResult(items: [], problems: [], skipped: 0)
    private var results: [ItemResult] = []
    private var destProblems: [String?]
    private var sourceGone = false
    private var destGone: [Bool]
    private var fatal: String?
    private var events: [TransferEvent] = []
    private var copyOrder: [Int] = []          // files in the order their copy finished
    private var sourceLost = false             // source went away since its last re-check
    private var corruptK: Int?                 // test only: the file being damaged
    private var sourceUUID: String?
    private var copyStarted = Date()
    private var copyFinished = Date()
    private let local: [Bool]
    public private(set) var sourceName: String
    public private(set) var targetVolumes: [String]
    private var n: Int { targets.count }
    private var files: [Int] = []

    public init(source: String, targets: [String], control: JobControl, progress: TransferProgress,
                stage: @escaping @Sendable (Stage) -> Void) {
        self.source = source
        self.targets = targets
        self.control = control
        self.progress = progress
        self.stage = stage
        destProblems = Array(repeating: nil, count: targets.count)
        destGone = Array(repeating: false, count: targets.count)
        local = targets.map { Plan.isLocal(URL(fileURLWithPath: ($0 as NSString).deletingLastPathComponent)) }
        sourceName = Plan.sourceName(URL(fileURLWithPath: source))
        targetVolumes = targets.map { Plan.volumeName(URL(fileURLWithPath: ($0 as NSString).deletingLastPathComponent)) }
    }

    /// Rebuilds a job from its saved state, to resume it.
    public convenience init(state: JobState, control: JobControl, progress: TransferProgress,
                            stage: @escaping @Sendable (Stage) -> Void) {
        self.init(source: state.source, targets: state.targets, control: control, progress: progress, stage: stage)
        scan = state.scan
        results = state.results
        destProblems = state.destinationProblems
        copyOrder = state.copyOrder
        events = state.events
        copyStarted = state.copyStarted
        sourceUUID = state.sourceVolumeUUID
        sourceLost = true   // after a quit we can't know what happened to it meanwhile
        if let s = state.sourceName { sourceName = s }
        if let v = state.targetVolumes, v.count == targets.count { targetVolumes = v }
        files = results.indices.filter { results[$0].item.kind != .folder }
        // Whatever was in flight when it stopped is unknown: the resume checks every destination.
        sourceGone = true
    }

    /// Current state, for the progress file.
    public var state: JobState {
        lock.withLock {
            JobState(source: source, sourceVolumeUUID: sourceUUID, targets: targets, scan: scan, results: results,
                     destinationProblems: destProblems, copyOrder: copyOrder, events: events, copyStarted: copyStarted,
                     sourceLost: sourceLost || sourceGone, sourceName: sourceName, targetVolumes: targetVolumes)
        }
    }

    private func event(_ text: String, bad: Bool = false) {
        lock.withLock { events.append(TransferEvent(date: Date(), text: text, bad: bad)) }
    }

    private func sourceAlive() -> Bool { FS.exists(source) }
    /// After a read error: is the source going away? An unplugged card can take a few seconds to vanish
    /// from /Volumes, and reads fail in the meantime. Wait up to 5 s before calling it a bad file.
    private func sourceDisappearing() -> Bool {
        if lock.withLock({ sourceGone }) { return true }
        for _ in 0..<25 {
            if !sourceAlive() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }
    /// Same for a destination after a write error.
    private func destDisappearing(_ d: Int) -> Bool {
        if lock.withLock({ destGone[d] }) { return true }
        for _ in 0..<25 {
            if !FS.exists(targets[d]) { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }
    private func destAlive(_ d: Int) -> Bool { FS.exists(targets[d]) }
    private var live: [Int] { (0..<n).filter { destProblems[$0] == nil && !destGone[$0] } }
    private var stopped: Bool { control.cancelled || lock.withLock { sourceGone || fatal != nil } }
    private func name(_ d: Int) -> String { targetVolumes[d] }
    /// The source went away since it was last checked, so a resume must re-check it.
    public var sourceNeedsRecheck: Bool { lock.withLock { sourceLost || sourceGone } }
    /// Gives up on an interrupted transfer: keeps what's there, marks the rest canceled.
    public func giveUp() -> TransferOutcome {
        control.cancelled = true
        event("Stopped here instead of resuming", bad: true)
        lock.withLock { sourceGone = false; destGone = destGone.map { _ in false } }
        return finish()
    }
    private func markSourceGone(_ why: String) {
        let first = lock.withLock { () -> Bool in
            defer { sourceGone = true; sourceLost = true }
            return !sourceGone
        }
        if first { event("\(sourceName) \(why)", bad: true) }
    }

    // MARK: First run

    public func start() -> TransferOutcome {
        stage(.scanning)
        sourceUUID = Engine.volumeUUID(source)
        scan = Scanner.scan(path: source)
        let parents = targets.map { URL(fileURLWithPath: ($0 as NSString).deletingLastPathComponent) }

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
            do { try FS.makeNewFolder(targets[d]) } catch { destProblems[d] = error.localizedDescription }
        }
        results = scan.items.map {
            ItemResult(item: $0, hash: nil, errors: destProblems, copied: Array(repeating: false, count: n),
                       verified: Array(repeating: false, count: n), retried: Array(repeating: false, count: n),
                       firstError: Array(repeating: nil, count: n), unverified: Array(repeating: [], count: n))
        }
        files = results.indices.filter { results[$0].item.kind != .folder }
        copyStarted = Date()
        stage(.copying)
        makeFolders()

        copy(files.map { k in (k, live) })
        copyFinished = Date()
        if !stopped { verify() }
        retry()
        return finish()
    }

    private func makeFolders() {
        for (i, r) in results.enumerated() where r.item.kind == .folder {
            for d in live where results[i].errors[d] == nil {
                do { try FS.makeFolders(FS.join(targets[d], r.item.path)) } catch {
                    results[i].errors[d] = error.localizedDescription
                }
            }
        }
    }

    // MARK: Copy

    /// Copies each (file, destinations) pair. Small files overlap; big ones go one at a time.
    /// Stops if the source disappears; a destination that disappears is left out until it's back.
    private func copy(_ work: [(Int, [Int])]) {
        guard !work.isEmpty, !live.isEmpty else { return }
        var next = 0
        let bigGate = DispatchSemaphore(value: 0)
        bigGate.signal()   // one big file at a time: cards and drives read best in one long run
        DispatchQueue.concurrentPerform(iterations: max(1, min(4, work.count))) { _ in
            while true {
                let job: (Int, [Int])? = lock.withLock {
                    guard next < work.count, !control.cancelled, !sourceGone, fatal == nil else { return nil }
                    defer { next += 1 }
                    return work[next]
                }
                guard let (k, wanted) = job else { return }
                let item = results[k].item
                let src = FS.join(source, item.path)
                let dests = lock.withLock { wanted.filter { !destGone[$0] && destProblems[$0] == nil && results[k].errors[$0] == nil } }
                if dests.isEmpty { continue }
                if item.kind == .link {
                    copyLink(k, src, dests)
                    continue
                }
                let big = item.size >= Engine.bigFile
                if big { bigGate.wait() }
                progress.update { $0.current = item.path }
                let out = MultiCopy.copy(src, to: dests.map { FS.join(targets[$0], item.path) },
                                         local: dests.map { local[$0] }, control: control,
                                         read: { b in self.progress.update { $0.read += b } },
                                         wrote: { i, b in self.progress.update { $0.written[dests[i]] += b } })
                if big { bigGate.signal() }
                record(k, dests, out, firstTry: true)
                progress.update { $0.filesCopied += 1 }
            }
        }
    }

    private func copyLink(_ k: Int, _ src: String, _ dests: [Int]) {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let len = readlink(src, &buf, Int(PATH_MAX))
        for d in dests {
            let dst = FS.join(targets[d], results[k].item.path)
            unlink(dst)
            if len >= 0, symlink(String(cString: buf), dst) == 0 {
                lock.withLock { results[k].copied[d] = true; results[k].verified[d] = true }
            } else if sourceDisappearing() {
                markSourceGone("disappeared during the copy (unplugged?)")
            } else {
                let e = FS.errorText()
                lock.withLock { results[k].errors[d] = "Couldn't copy link: \(e)" }
            }
        }
    }

    /// Books the outcome of copying one file. Failures caused by a drive disappearing don't count
    /// against the file: it simply hasn't been copied yet.
    private func record(_ k: Int, _ dests: [Int], _ out: MultiCopy.FileOutcome, firstTry: Bool) {
        let item = results[k].item
        if out.sourceError != nil && !control.cancelled && sourceDisappearing() {
            markSourceGone("disappeared during the copy (unplugged?)")
            return
        }
        if Engine.corruptForTest, item.size > 2000, out.errors.allSatisfy({ $0 == nil }), out.sourceError == nil,
           dests.first == 0, firstTry || Engine.corruptAlwaysForTest,
           lock.withLock({ () -> Bool in
               if corruptK == nil && firstTry { corruptK = k }
               return corruptK == k && (firstTry || Engine.corruptAlwaysForTest)
           }) {
            let fd = open(FS.join(targets[0], item.path), O_WRONLY)
            var b: UInt8 = 0x5A
            _ = pwrite(fd, &b, 1, 1000)
            close(fd)
        }
        var gone: [Int] = []
        // Write errors might be a drive being unplugged: give it a moment to show (outside the lock).
        let vanishing = Set(dests.enumerated().filter { out.sourceError == nil && out.errors[$0.offset] != nil && destDisappearing($0.element) }.map(\.element))
        lock.withLock {
            if let h = out.hash { results[k].hash = XXHash64.hex(h) }
            for (i, d) in dests.enumerated() {
                if let e = out.sourceError ?? out.errors[i] {
                    if vanishing.contains(d) {
                        if !destGone[d] { gone.append(d) }
                        destGone[d] = true
                    } else {
                        results[k].errors[d] = e
                    }
                } else {
                    results[k].copied[d] = true
                }
            }
            if out.hash != nil && results[k].copied.contains(true) && !copyOrder.contains(k) { copyOrder.append(k) }
        }
        for d in gone { event("\(name(d)) disappeared during the copy (unplugged?)", bad: true) }
    }

    // MARK: Verify

    /// Reads one copy back off its drive and compares it with the source checksum.
    private func verifyOne(_ k: Int, _ d: Int, counting: Bool) {
        let url = FS.join(targets[d], results[k].item.path)
        let expected = lock.withLock { results[k].hash }
        var err: String?
        do {
            // If none of the copy is in memory, a normal read must come off the drive, and its
            // read-ahead is far faster. Otherwise force every byte to come off the drive.
            let cached = MultiCopy.residentFraction(url) == 0
            let h = XXHash64.hex(try MultiCopy.hashFile(url, control: control, depth: cached ? 1 : 4, cached: cached) { b in
                if counting { self.progress.update { $0.verified[d] += b } }
            })
            if h != expected { err = "Checksum didn't match: source \(expected ?? "?"), destination \(h)" }
        } catch CopyError.cancelled {
            return
        } catch {
            if !control.cancelled && destDisappearing(d) {
                let first = lock.withLock { () -> Bool in defer { destGone[d] = true }; return !destGone[d] }
                if first { event("\(name(d)) disappeared during the verify (unplugged?)", bad: true) }
                return
            }
            err = error.localizedDescription
        }
        lock.withLock {
            results[k].errors[d] = err
            results[k].verified[d] = err == nil
        }
        if counting { progress.update { $0.filesVerified[d] += 1 } }
    }

    /// Reads back every copied-but-unchecked file on every reachable destination (destinations at once).
    private func verify() {
        stage(.verifying)
        DispatchQueue.concurrentPerform(iterations: n) { d in
            guard lock.withLock({ destProblems[d] == nil && !destGone[d] }) else { return }
            let mine = files.filter { k in
                lock.withLock { results[k].copied[d] && !results[k].verified[d] && results[k].errors[d] == nil && results[k].hash != nil }
            }
            var nextFile = 0
            let gate = DispatchSemaphore(value: 0)
            gate.signal()
            DispatchQueue.concurrentPerform(iterations: max(1, min(3, mine.count))) { _ in
                while true {
                    let k: Int? = lock.withLock {
                        guard nextFile < mine.count, !control.cancelled, !destGone[d] else { return nil }
                        defer { nextFile += 1 }
                        return mine[nextFile]
                    }
                    guard let k else { return }
                    let big = results[k].item.size >= Engine.bigFile
                    if big { gate.wait() }
                    verifyOne(k, d, counting: true)
                    if big { gate.signal() }
                }
            }
        }
    }

    // MARK: Failed files

    /// Moves a copy that failed its verify out of the real copy into "<name> Unverified", same folders.
    private func moveToUnverified(_ k: Int, _ d: Int) {
        let path = results[k].item.path
        let from = FS.join(targets[d], path)
        guard FS.exists(from) else { return }
        var to = FS.join(Engine.unverifiedFolder(forTarget: targets[d]), path)
        let ext = (path as NSString).pathExtension
        let stem = ((to as NSString).lastPathComponent as NSString).deletingPathExtension
        var i = 2
        while FS.exists(to) {
            to = FS.join((to as NSString).deletingLastPathComponent, "\(stem) (try \(i))" + (ext.isEmpty ? "" : "." + ext))
            i += 1
        }
        do {
            try FS.makeFolders((to as NSString).deletingLastPathComponent)
            if rename(from, to) != 0 { throw CopyError.io(FS.errorText()) }
            lock.withLock { results[k].unverified[d].append(to) }
        } catch {
            unlink(from)   // couldn't move it: the real copy must never hold a bad file
        }
    }

    /// Copies just the failed files again from the source, to just the destinations they failed on, and
    /// verifies them again. Two more tries, with a pause before each so a network share can recover.
    private func retry() {
        for attempt in 1...2 where !stopped {
            let failed = files.filter { k in
                results[k].item.kind == .file && live.contains { d in results[k].errors[d] != nil && !results[k].verified[d] }
            }
            if failed.isEmpty { break }
            stage(.retrying(failed.count))
            Thread.sleep(forTimeInterval: 2)
            for k in failed where !stopped {
                guard sourceAlive() else {
                    markSourceGone("disappeared before failed files could be copied again")
                    break
                }
                let item = results[k].item
                let dests = live.filter { results[k].errors[$0] != nil && !results[k].verified[$0] }
                for d in dests {
                    if results[k].firstError[d] == nil { results[k].firstError[d] = results[k].errors[d] }
                    // A copy that was written but failed its verify is kept for checking; anything else was ours to redo.
                    if results[k].copied[d] { moveToUnverified(k, d) } else { unlink(FS.join(targets[d], item.path)) }
                    results[k].errors[d] = nil
                    results[k].copied[d] = false
                    results[k].retried[d] = true
                }
                progress.update { $0.current = item.path }
                let before = results[k].hash
                let out = MultiCopy.copy(FS.join(source, item.path), to: dests.map { FS.join(targets[$0], item.path) },
                                         local: dests.map { local[$0] }, control: control, read: { _ in }, wrote: { _, _ in })
                if let h = out.hash.map(XXHash64.hex), let before, h != before, out.sourceError == nil {
                    // The source gave different data this time: the card or reader can't be trusted.
                    for (i, d) in dests.enumerated() {
                        results[k].copied[d] = out.errors[i] == nil
                        results[k].errors[d] = "The source read differently on attempt \(attempt + 1) (\(before) then \(h)). The card or reader may be failing."
                    }
                    continue
                }
                record(k, dests, out, firstTry: false)
                for d in dests where results[k].copied[d] {
                    verifyOne(k, d, counting: false)
                    if let e = results[k].errors[d] { results[k].errors[d] = "Attempt \(attempt + 1): \(e)" }
                }
                for d in dests where !results[k].copied[d] && results[k].errors[d] != nil {
                    results[k].errors[d] = "Attempt \(attempt + 1): \(results[k].errors[d]!)"
                }
            }
        }
    }

    // MARK: Wrapping up

    private func finish() -> TransferOutcome {
        let interrupted = lock.withLock { fatal == nil && (sourceGone || destGone.contains(true)) }
        if !interrupted {
            // A copy that still fails its verify after the last try leaves the real copy too.
            for k in files where results[k].item.kind == .file {
                for d in 0..<n where results[k].copied[d] && results[k].errors[d] != nil { moveToUnverified(k, d) }
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
                for d in 0..<n where destProblems[d] == nil && results[k].errors[d] == nil && !results[k].verified[d] {
                    results[k].errors[d] = control.cancelled ? "Canceled before it was copied and verified"
                        : fatal != nil ? (results[k].copied[d] ? "Copied, but couldn't be verified" : "Not copied: the transfer stopped")
                        : "Not verified"
                }
            }
        }
        return lock.withLock {
            TransferOutcome(scan: scan, results: results, destinationProblems: destProblems, canceled: control.cancelled,
                            sourceGone: sourceGone, destGone: destGone, fatal: fatal, events: events,
                            copyStarted: copyStarted, copyFinished: copyFinished, verifyFinished: Date())
        }
    }

    // MARK: Resume after an unplug (or a quit)

    /// What's missing before a resume can start, in plain words; nil when everything is back.
    public func waitingFor() -> String? {
        var missing: [String] = []
        if !sourceAlive() { missing.append(sourceName) }
        for d in 0..<n where destProblems[d] == nil && !FS.exists((targets[d] as NSString).deletingLastPathComponent) {
            missing.append(name(d))
        }
        return missing.isEmpty ? nil : missing.joined(separator: " and ")
    }

    /// Bytes each kind of resume reads from the source (for the time estimate on the buttons).
    public func recheckBytes(_ mode: ResumeMode) -> Int64 {
        let done = results.filter { $0.item.kind == .file && $0.hash != nil && $0.copied.contains(true) }
        switch mode {
        case .full: return done.reduce(0) { $0 + $1.item.size }
        case .quick:
            let tail = Set(copyOrder.suffix(2))
            return files.reduce(0) { sum, k in
                let r = results[k]
                guard r.item.kind == .file, r.hash != nil, r.copied.contains(true) else { return sum }
                return sum + (tail.contains(k) ? r.item.size : min(r.item.size, 2 * MultiCopy.sampleBytes))
            }
        }
    }

    /// Bytes to read back on the destinations before carrying on.
    public var destinationRecheckBytes: Int64 {
        results.reduce(0) { sum, r in
            sum + (r.item.kind == .file ? Int64(r.copied.indices.filter { r.copied[$0] && !r.verified[$0] }.count) * r.item.size : 0)
        }
    }

    /// Checks it's the same source, re-checks the source (full or quick) and every destination at the same
    /// time, then copies and verifies whatever is left. `leaveOut` drops destinations that aren't coming back.
    public func resume(_ mode: ResumeMode, leaveOut: [Int] = []) -> TransferOutcome {
        for d in leaveOut where destProblems[d] == nil {
            destProblems[d] = "Unplugged and left out of the rest of the transfer"
            event("\(name(d)) was left out of the rest of the transfer", bad: true)
        }
        if let w = waitingFor() {
            event("Tried to resume, but \(w) isn't connected", bad: true)
            return finish()
        }
        stage(.rechecking)
        let label = sourceName
        let checkSource = sourceLost || sourceGone

        // 1. Same card? Its ID and every name, size and date must match the first look.
        if checkSource, let was = sourceUUID, let now = Engine.volumeUUID(source), was != now {
            return stopForGood("\(label) that came back is a different card or drive (its ID changed). Nothing more was copied.")
        }
        let again = checkSource ? Scanner.scan(path: source) : scan
        if again.items != scan.items {
            let changed = Set(again.items).symmetricDifference(Set(scan.items)).map(\.path).sorted().prefix(3)
            return stopForGood("\(label) changed while it was unplugged (\(changed.joined(separator: ", "))). Nothing more was copied.")
        }
        lock.withLock { sourceGone = false }
        for d in 0..<n where destGone[d] {
            if destAlive(d) { destGone[d] = false } else {
                destProblems[d] = "The copy folder is missing from \(name(d))"
            }
        }
        event(checkSource ? "Resumed with a \(mode == .full ? "full re-read" : "quick check") of \(label)" : "Resumed")

        // 2. Re-check the source and the destinations at the same time.
        tidyPartials()
        let srcBytes = checkSource ? recheckBytes(mode) : 0
        progress.update {
            $0.recheckSourceDone = 0; $0.recheckSourceTotal = srcBytes
            $0.recheckDestDone = 0; $0.recheckDestTotal = destinationRecheckBytes
        }
        var sourceProblem: String?
        let group = DispatchGroup()
        if checkSource {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                sourceProblem = self.recheckSource(mode)
            }
        }
        recheckDestinations()
        group.wait()
        if let sourceProblem { return stopForGood(sourceProblem) }
        if control.cancelled { return finish() }
        if checkSource { event("\(label) re-checked: it matches what was copied before") }
        lock.withLock { sourceLost = false }
        let rechecked = destinationRecheckBytes
        _ = rechecked

        // 3. Copy what's left, verify it, retry anything that failed.
        stage(.copying)
        makeFolders()
        let work = files.compactMap { k -> (Int, [Int])? in
            let ds = live.filter { !results[k].copied[$0] && results[k].errors[$0] == nil }
            return ds.isEmpty ? nil : (k, ds)
        }
        copy(work)
        copyFinished = Date()
        if !stopped { verify() }
        retry()
        return finish()
    }

    private func stopForGood(_ why: String) -> TransferOutcome {
        event(why, bad: true)
        // What was copied before still has its checksum from the first read: verify those copies, so
        // they're usable even though the rest can't be copied.
        lock.withLock { sourceGone = false }
        for d in 0..<n where destGone[d] && destAlive(d) { destGone[d] = false }
        tidyPartials()
        recheckDestinations()
        lock.withLock { fatal = why; destGone = destGone.map { _ in false } }
        return finish()
    }

    /// Leftovers of the copy that was cut off: hidden partial files, and finished copies the progress
    /// file hadn't caught up with (checked against the source checksum if there is one, else redone).
    private func tidyPartials() {
        for k in files where results[k].item.kind == .file {
            for d in live where !results[k].copied[d] {
                let p = FS.join(targets[d], results[k].item.path)
                unlink(FS.join((p as NSString).deletingLastPathComponent, "." + (p as NSString).lastPathComponent + MultiCopy.partialSuffix))
                if FS.exists(p) {
                    if results[k].hash != nil { results[k].copied[d] = true } else { unlink(p) }
                }
            }
        }
    }

    /// Full: every already-copied file read again from the source and compared with its first checksum.
    /// Quick: the start and end of each file compared with a destination copy (which is fully verified at
    /// the same time), plus the last two files copied before the unplug read in full.
    private func recheckSource(_ mode: ResumeMode) -> String? {
        let done = files.filter { results[$0].item.kind == .file && results[$0].hash != nil && results[$0].copied.contains(true) }
        let fullSet: Set<Int> = mode == .full ? Set(done) : Set(copyOrder.suffix(2))
        for k in done {
            if control.cancelled { return nil }
            let item = results[k].item
            let src = FS.join(source, item.path)
            if fullSet.contains(k) {
                do {
                    let h = XXHash64.hex(try MultiCopy.hashFile(src, control: control, depth: 1, cached: true) { b in
                        self.progress.update { $0.recheckSourceDone += b }
                    })
                    if h != results[k].hash {
                        return "\(item.path) reads differently from the source than before the unplug (\(results[k].hash!) then \(h)). Don't trust this card or reader. Copies made before the unplug are kept."
                    }
                } catch {
                    return "Couldn't re-read \(item.path) from the source: \(error.localizedDescription)"
                }
            } else {
                guard let d = (0..<n).first(where: { results[k].copied[$0] && destProblems[$0] == nil }) else { continue }
                let a = MultiCopy.sample(src), b = MultiCopy.sample(FS.join(targets[d], item.path))
                progress.update { $0.recheckSourceDone += min(item.size, 2 * MultiCopy.sampleBytes) }
                if a == nil || a != b {
                    return "\(item.path): the start or end of the file on the source no longer matches the copy. Don't trust this card or reader. Copies made before the unplug are kept."
                }
            }
        }
        return nil
    }

    /// Every copy that hadn't been verified yet is read back now (all destinations at once).
    private func recheckDestinations() {
        DispatchQueue.concurrentPerform(iterations: n) { d in
            guard destProblems[d] == nil, !destGone[d] else { return }
            for k in files where results[k].copied[d] && !results[k].verified[d] && results[k].hash != nil {
                if control.cancelled { return }
                verifyOne(k, d, counting: false)
                progress.update { $0.recheckDestDone += results[k].item.size }
            }
        }
    }
}
