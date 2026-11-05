import Foundation

/// Pause / cancel switch shared between the UI and a running transfer.
public final class JobControl: @unchecked Sendable {
    private let lock = NSLock()
    private var _paused = false
    private var _cancelled = false
    public init() {}
    public var paused: Bool {
        get { lock.withLock { _paused } }
        set { lock.withLock { _paused = newValue } }
    }
    public var cancelled: Bool {
        get { lock.withLock { _cancelled } }
        set { lock.withLock { _cancelled = newValue } }
    }
    /// Blocks while paused. Returns false once cancelled.
    public func checkpoint() -> Bool {
        while paused && !cancelled { Thread.sleep(forTimeInterval: 0.1) }
        return !cancelled
    }
}

/// One thing inside the source folder, path relative to the source folder ("" is never used).
public struct SourceItem: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable { case folder, file, link }
    public var path: String
    public var kind: Kind
    public var size: Int64
    public var modified: Date?
}

public struct ScanProblem: Sendable, Codable, Hashable {
    public var path: String
    public var reason: String
}

public struct ScanResult: Sendable, Codable {
    public var items: [SourceItem]
    public var problems: [ScanProblem]        // folders or files that couldn't be read
    public var skipped: Int                   // system files left out (.DS_Store, Spotlight, Trash…)
    public init(items: [SourceItem], problems: [ScanProblem], skipped: Int) {
        self.items = items
        self.problems = problems
        self.skipped = skipped
    }
    public var files: Int { items.filter { $0.kind != .folder }.count }
    public var bytes: Int64 { items.reduce(0) { $0 + ($1.kind == .file ? $1.size : 0) } }
}

public enum Scanner {
    /// Mac housekeeping files and folders that are never part of what was shot.
    public static let systemNames: Set<String> = [
        ".DS_Store", ".Spotlight-V100", ".Trashes", ".fseventsd", ".TemporaryItems",
        ".DocumentRevisions-V100", ".VolumeIcon.icns", ".com.apple.timemachine.donotpresent",
        "$RECYCLE.BIN", "System Volume Information",
    ]

    public static func isSystem(_ name: String) -> Bool {
        systemNames.contains(name) || name.hasPrefix("._")
    }

    /// Everything under `root`, hidden files included, folders before their contents. Names are read
    /// straight from the disk (readdir) so they're recreated byte for byte.
    public static func scan(_ root: URL) -> ScanResult { scan(path: root.path) }

    /// `found` is told how many things have been listed so far, every few hundred (for a live count).
    public static func scan(path root: String, only: [String]? = nil, found: ((Int) -> Void)? = nil) -> ScanResult {
        var items: [SourceItem] = []
        var problems: [ScanProblem] = []
        var skipped = 0
        func walk(_ rel: String) {
            let dir = FS.join(root, rel)
            guard let d = opendir(dir) else {
                problems.append(ScanProblem(path: rel.isEmpty ? "(the source folder)" : rel, reason: "Couldn't read this folder: \(FS.errorText())"))
                return
            }
            var names: [String] = []
            while let e = readdir(d) {
                var ent = e.pointee
                let name = withUnsafePointer(to: &ent.d_name) {
                    String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
                }
                if name == "." || name == ".." { continue }
                names.append(name)
            }
            closedir(d)
            names.sort { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            for name in names {
                if isSystem(name) { skipped += 1; continue }
                let r = rel.isEmpty ? name : rel + "/" + name
                guard let st = FS.lstatInfo(FS.join(root, r)) else {
                    problems.append(ScanProblem(path: r, reason: "Couldn't read: \(FS.errorText())"))
                    continue
                }
                let mtime = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9)
                if items.count % 250 == 0 { found?(items.count) }
                switch st.st_mode & S_IFMT {
                case S_IFDIR:
                    items.append(SourceItem(path: r, kind: .folder, size: 0, modified: mtime))
                    walk(r)
                case S_IFLNK:
                    items.append(SourceItem(path: r, kind: .link, size: 0, modified: mtime))
                case S_IFREG:
                    items.append(SourceItem(path: r, kind: .file, size: Int64(st.st_size), modified: mtime))
                default:
                    problems.append(ScanProblem(path: r, reason: "Not a regular file (device, socket or pipe); left out"))
                }
            }
        }
        if let only {
            // Just the selected files and folders inside `root`.
            for name in only.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
                guard let st = FS.lstatInfo(FS.join(root, name)) else {
                    problems.append(ScanProblem(path: name, reason: "Couldn't read: \(FS.errorText())"))
                    continue
                }
                let mtime = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9)
                switch st.st_mode & S_IFMT {
                case S_IFDIR: items.append(SourceItem(path: name, kind: .folder, size: 0, modified: mtime)); walk(name)
                case S_IFLNK: items.append(SourceItem(path: name, kind: .link, size: 0, modified: mtime))
                case S_IFREG: items.append(SourceItem(path: name, kind: .file, size: Int64(st.st_size), modified: mtime))
                default: problems.append(ScanProblem(path: name, reason: "Not a regular file (device, socket or pipe); left out"))
                }
            }
        } else {
            walk("")
        }
        found?(items.count)
        return ScanResult(items: items, problems: problems, skipped: skipped)
    }
}

/// Where things land in each destination, and checks before starting.
public enum Plan {
    /// "CLIP", or "CLIP 2", "CLIP 3"… if that name is already taken in `parent`. Never overwrites.
    public static func targetName(for source: URL, in parent: URL, also taken: Set<String> = []) -> String {
        let base = sourceName(source)
        func free(_ n: String) -> Bool {
            !taken.contains(n.lowercased())
                && !FS.exists(FS.join(parent.path, n)) && !FS.exists(FS.join(parent.path, n + " Reports"))
                && !FS.exists(FS.join(parent.path, n + " Unverified"))
        }
        if free(base) { return base }
        var i = 2
        while !free("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }

    /// A file or folder's name exactly as it's stored on disk (URL can hand it back in another Unicode form).
    public static func exactName(_ url: URL) -> String {
        let want = url.lastPathComponent
        if let d = opendir(url.deletingLastPathComponent().path) {
            defer { closedir(d) }
            while let e = readdir(d) {
                var ent = e.pointee
                let name = withUnsafePointer(to: &ent.d_name) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
                if name == want { return name }
            }
        }
        return want
    }

    /// The folder name the source is recreated under. A whole card uses its volume name.
    public static func sourceName(_ source: URL) -> String {
        if source.path == "/" { return "Macintosh HD" }
        let v = try? source.resourceValues(forKeys: [.isVolumeKey, .volumeLocalizedNameKey])
        if v?.isVolume == true, let n = v?.volumeLocalizedName, !n.isEmpty { return n }
        // URL may hand back the name in another Unicode form; use the bytes the folder really has.
        let want = source.lastPathComponent
        let parent = source.deletingLastPathComponent().path
        if let d = opendir(parent) {
            defer { closedir(d) }
            while let e = readdir(d) {
                var ent = e.pointee
                let name = withUnsafePointer(to: &ent.d_name) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
                if name == want { return name }   // Swift == treats both Unicode forms as equal
            }
        }
        return want
    }

    /// "HVP SSD 07", or "Macintosh HD" for the Mac's own drive.
    public static func volumeName(_ url: URL) -> String {
        (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName ?? "Macintosh HD"
    }

    public static func freeSpace(_ url: URL) -> Int64? {
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let n = v?.volumeAvailableCapacityForImportantUsage, n > 0 { return n }
        return v?.volumeAvailableCapacity.map(Int64.init)
    }

    public static func isLocal(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal ?? true
    }

    /// Plain-English reason a destination can't be used with this source, or nil if it's fine.
    public static func problem(source: URL?, destination: URL, others: [URL]) -> String? {
        let d = destination.standardizedFileURL.resolvingSymlinksInPath().path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: d, isDirectory: &isDir), isDir.boolValue else {
            return "Not a folder"
        }
        guard FileManager.default.isWritableFile(atPath: d) else { return "Can't write to this folder" }
        if others.contains(where: { $0.standardizedFileURL.resolvingSymlinksInPath().path == d }) {
            return "Already a destination"
        }
        if let source {
            let s = source.standardizedFileURL.resolvingSymlinksInPath().path
            if d == s || d.hasPrefix(s == "/" ? "/" : s + "/") && s != "/" { return "Inside the source folder" }
        }
        return nil
    }
}
