import Foundation

public enum CopyError: LocalizedError, Equatable {
    case cancelled
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: "Canceled"
        case let .io(m): m
        }
    }
}

/// Reads a file once and writes it to every destination at the same time.
public enum MultiCopy {
    public static let chunk = 8 * 1024 * 1024
    public static let partialSuffix = ".cloneranger-partial"
    /// Test only: caps the read speed (bytes per second) so screenshots can catch a transfer mid-way.
    nonisolated(unsafe) public static var throttle: Double = 0
    /// Read the source through the memory cache. The cache's read-ahead is much faster on USB SSDs
    /// (980 vs 700 MB/s measured on HVP SSD 07); the checksum is still taken from what was read.
    nonisolated(unsafe) public static var sourceCached = true
    // Tuning knobs (benchmarks only).
    nonisolated(unsafe) public static var copyChunk = 8 * 1024 * 1024
    nonisolated(unsafe) public static var destCached = false

    public struct FileOutcome: Sendable {
        public var hash: UInt64?
        public var errors: [String?]      // one per destination
        public var sourceError: String?   // problem reading the source: every destination failed
    }

    /// Copies `src` to each of `dsts`, hashing as it reads. A destination that fails doesn't stop
    /// the others. Finished copies are written under a hidden partial name, then renamed.
    /// `read` gets bytes read from the source, `wrote` gets (destination index, bytes written).
    public static func copy(_ src: String, to dsts: [String], local: [Bool], control: JobControl,
                            read readProgress: (Int64) -> Void,
                            wrote: @escaping @Sendable (Int, Int64) -> Void) -> FileOutcome {
        let n = dsts.count
        var outcome = FileOutcome(hash: nil, errors: Array(repeating: nil, count: n))
        guard let before = FS.lstatInfo(src) else {
            outcome.sourceError = "File is no longer in the source"
            return outcome
        }
        let srcSize = Int64(before.st_size)
        let inFD = open(src, O_RDONLY)
        guard inFD >= 0 else {
            outcome.sourceError = "Couldn't open in the source: \(String(cString: strerror(errno)))"
            return outcome
        }
        defer { close(inFD) }
        if !sourceCached { _ = fcntl(inFD, F_NOCACHE, 1) }

        let tmps = dsts.map { FS.join(($0 as NSString).deletingLastPathComponent, "." + ($0 as NSString).lastPathComponent + partialSuffix) }
        var fds = [Int32](repeating: -1, count: n)
        for d in 0..<n {
            unlink(tmps[d])
            let fd = open(tmps[d], O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            if fd < 0 {
                outcome.errors[d] = "Couldn't write to the destination: \(String(cString: strerror(errno)))"
            } else {
                fds[d] = fd
                // Local drives: skip the memory cache so the verify read truly comes back off the drive.
                // Network shares keep it (uncached SMB writes lose their batching).
                if local[d] && !destCached { _ = fcntl(fd, F_NOCACHE, 1) }
            }
        }

        // A ring of buffers: the source fills one while every destination writes the ones before it.
        let slots = 4
        let size = Int(max(1, min(Int64(copyChunk), srcSize)))
        let bufs = (0..<slots).map { _ in UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 4096) }
        defer { bufs.forEach { $0.deallocate() } }
        var lens = [Int](repeating: 0, count: slots)
        var remaining = [Int](repeating: 0, count: slots)
        var errors = outcome.errors
        let lock = NSLock()
        // Semaphores start at 0 and are signalled up (libdispatch traps if one is freed below its start value).
        let free = DispatchSemaphore(value: 0)
        for _ in 0..<slots { free.signal() }
        let full = (0..<n).map { _ in DispatchSemaphore(value: 0) }
        let group = DispatchGroup()

        for d in 0..<n {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                var slot = 0
                while true {
                    full[d].wait()
                    let len = lens[slot]
                    if len <= 0 { return }
                    let ok = lock.withLock { errors[d] == nil }
                    if ok {
                        var off = 0
                        while off < len {
                            let w = write(fds[d], bufs[slot] + off, len - off)
                            if w < 0 {
                                if errno == EINTR { continue }
                                let msg = errno == ENOSPC ? "The destination drive is full" : String(cString: strerror(errno))
                                lock.withLock { errors[d] = "Write error: \(msg)" }
                                break
                            }
                            off += w
                        }
                        if off == len { wrote(d, Int64(len)) }
                    }
                    let freed = lock.withLock { () -> Bool in
                        remaining[slot] -= 1
                        return remaining[slot] == 0
                    }
                    if freed { free.signal() }
                    slot = (slot + 1) % slots
                }
            }
        }

        var hasher = XXHash64()
        var slot = 0
        var readError: String?
        let started = Date()
        var total: Int64 = 0
        while true {
            free.wait()
            var len = 0
            if !control.checkpoint() {
                readError = CopyError.cancelled.localizedDescription
                len = -1
            } else if lock.withLock({ errors.allSatisfy { $0 != nil } }) {
                len = -1   // every destination has failed; stop reading
            } else {
                var r = read(inFD, bufs[slot], size)
                while r < 0 && errno == EINTR { r = read(inFD, bufs[slot], size) }
                if r < 0 {
                    readError = "Read error in the source: \(String(cString: strerror(errno)))"
                    len = -1
                } else {
                    len = r
                    if r > 0 { hasher.update(UnsafeRawBufferPointer(start: bufs[slot], count: r)) }
                }
            }
            lens[slot] = len
            lock.withLock { remaining[slot] = n }
            for s in full { s.signal() }
            if len <= 0 { break }
            readProgress(Int64(len))
            total += Int64(len)
            if throttle > 0 {
                let ahead = Double(total) / throttle - Date().timeIntervalSince(started)
                if ahead > 0 { Thread.sleep(forTimeInterval: ahead) }
            }
            slot = (slot + 1) % slots
        }
        group.wait()

        // The source must not have changed while it was read.
        if readError == nil {
            let after = FS.lstatInfo(src)
            if after == nil || after!.st_size != before.st_size
                || after!.st_mtimespec.tv_sec != before.st_mtimespec.tv_sec
                || after!.st_mtimespec.tv_nsec != before.st_mtimespec.tv_nsec {
                readError = "File changed in the source while it was being copied"
            } else if total != srcSize && errors.contains(where: { $0 == nil }) {
                readError = "Read \(total) bytes but the file is \(srcSize) bytes"
            }
        }

        for d in 0..<n where fds[d] >= 0 {
            if errors[d] == nil && readError == nil && fsync(fds[d]) != 0 {
                errors[d] = "Couldn't finish writing: \(String(cString: strerror(errno)))"
            }
            close(fds[d])
        }

        for d in 0..<n {
            if readError != nil || errors[d] != nil {
                unlink(tmps[d])
                continue
            }
            // Finder tags and other extended attributes (best effort), then dates and permissions.
            _ = copyfile(src, tmps[d], nil, copyfile_flags_t(COPYFILE_XATTR))
            FS.setDates(tmps[d], modified: before.st_mtimespec, created: before.st_birthtimespec)
            _ = chmod(tmps[d], before.st_mode & 0o7777)
            // Never replace anything already there.
            if FS.exists(dsts[d]) {
                errors[d] = "Something named \((dsts[d] as NSString).lastPathComponent) is already in the destination"
                unlink(tmps[d])
            } else if rename(tmps[d], dsts[d]) != 0 {
                errors[d] = "Couldn't put the copy in place: \(FS.errorText())"
                unlink(tmps[d])
            }
        }

        outcome.errors = errors
        outcome.sourceError = readError
        if readError == nil { outcome.hash = hasher.finalize() }
        return outcome
    }

    /// How much of the start and of the end of a file the quick check compares.
    public static let sampleBytes: Int64 = 64 * 1024 * 1024

    /// xxHash64 of the first and last `sampleBytes` of a file (the whole file if it's smaller), or nil.
    public static func sample(_ path: String) -> String? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return nil }
        let size = Int64(st.st_size)
        let buf = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 4096)
        defer { buf.deallocate() }
        var hasher = XXHash64()
        let ranges: [(Int64, Int64)] = size <= 2 * sampleBytes ? [(Int64(0), size)] : [(Int64(0), sampleBytes), (size - sampleBytes, size)]
        for (from, to) in ranges {
            var off = from
            while off < to {
                let r = pread(fd, buf, Int(min(Int64(chunk), to - off)), off_t(off))
                if r < 0 { if errno == EINTR { continue }; return nil }
                if r == 0 { return nil }
                hasher.update(UnsafeRawBufferPointer(start: buf, count: r))
                off += Int64(r)
            }
        }
        return "\(size):" + XXHash64.hex(hasher.finalize())
    }

    /// How much of a file is sitting in the Mac's memory cache right now (0…1), from mincore().
    public static func residentFraction(_ path: String) -> Double {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return 1 }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size > 0 else { return 0 }
        let page = Int(getpagesize())
        let window = 1 << 30
        var resident = 0, pages = 0
        var off: off_t = 0
        while off < st.st_size {
            let len = Int(min(off_t(window), st.st_size - off))
            guard let p = mmap(nil, len, PROT_READ, MAP_SHARED, fd, off), p != MAP_FAILED else { return 1 }
            let n = (len + page - 1) / page
            var vec = [CChar](repeating: 0, count: n)
            let ok = mincore(p, len, &vec) == 0
            munmap(p, len)
            guard ok else { return 1 }
            resident += vec.reduce(0) { $0 + (($1 & 1) != 0 ? 1 : 0) }
            pages += n
            off += off_t(len)
        }
        return pages == 0 ? 0 : Double(resident) / Double(pages)
    }

    /// xxHash64 of a file read back off the drive (not the memory cache). Keeps `depth` reads in
    /// flight at once: uncached reads one at a time leave an SSD idle between requests.
    public static func hashFile(_ path: String, control: JobControl? = nil, depth: Int = 4, chunk: Int = MultiCopy.chunk, cached: Bool = false,
                                progress: (Int64) -> Void = { _ in }) throws -> UInt64 {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw CopyError.io("Couldn't open \((path as NSString).lastPathComponent): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        if !cached { _ = fcntl(fd, F_NOCACHE, 1) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw CopyError.io("Couldn't read \((path as NSString).lastPathComponent)") }
        let size = Int64(st.st_size)
        let d = size > Int64(chunk) ? max(1, depth) : 1
        let bufs = (0..<d).map { _ in UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 4096) }
        defer { bufs.forEach { $0.deallocate() } }
        var lens = [Int](repeating: 0, count: d)
        var errs = [Int32](repeating: 0, count: d)
        var hasher = XXHash64()
        var offset: Int64 = 0
        while true {
            if let control, !control.checkpoint() { throw CopyError.cancelled }
            // Read the next `d` chunks at the same time, then hash them in order.
            DispatchQueue.concurrentPerform(iterations: d) { j in
                let at = offset + Int64(j) * Int64(chunk)
                var got = 0
                while got < chunk {
                    let r = pread(fd, bufs[j] + got, chunk - got, off_t(at) + off_t(got))
                    if r < 0 { if errno == EINTR { continue }; errs[j] = errno; break }
                    if r == 0 { break }
                    got += r
                }
                lens[j] = got
            }
            if let e = errs.first(where: { $0 != 0 }) { throw CopyError.io("Read error: \(String(cString: strerror(e)))") }
            var end = false
            for j in 0..<d {
                if lens[j] > 0 {
                    hasher.update(UnsafeRawBufferPointer(start: bufs[j], count: lens[j]))
                    progress(Int64(lens[j]))
                    offset += Int64(lens[j])
                }
                if lens[j] < chunk { end = true; break }
            }
            if end { break }
        }
        return hasher.finalize()
    }
}
