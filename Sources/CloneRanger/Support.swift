import AppKit
import CRCore
import IOKit.ps
import UserNotifications

/// Progress files for transfers that haven't finished, so a quit or crash can be picked back up.
/// ~/Library/Application Support/Clone Ranger/Unfinished/<id>.json, removed when the transfer ends.
@MainActor
enum Journal {
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = ProcessInfo.processInfo.environment["CR_JOURNAL_DIR"].map { URL(fileURLWithPath: $0) }
            ?? base.appendingPathComponent("Clone Ranger/Unfinished")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Transfers whose progress file is being written right now. A transfer of a hundred thousand files makes
    /// a big file that takes a moment to write; saves never pile up behind each other.
    private static var saving: Set<UUID> = []

    static func save(_ t: Transfer) {
        guard let job = t.job, !saving.contains(t.id) else { return }
        saving.insert(t.id)
        let id = t.id
        let url = folder.appendingPathComponent(t.id.uuidString + ".json")
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(job.state) { try? data.write(to: url, options: .atomic) }
            await MainActor.run { _ = saving.remove(id) }
        }
    }

    /// Right now, on this thread (when quitting).
    static func saveNow(_ t: Transfer) {
        guard let job = t.job, let data = try? JSONEncoder().encode(job.state) else { return }
        try? data.write(to: folder.appendingPathComponent(t.id.uuidString + ".json"), options: .atomic)
    }

    static func remove(_ t: Transfer) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(t.id.uuidString + ".json"))
    }

    /// Only one running Clone Ranger may pick up unfinished transfers: the first to start holds this lock
    /// for as long as it runs, so a second copy never shows (or resumes) the first one's work in progress.
    nonisolated(unsafe) private static var lockFD: Int32 = -1
    static func claim() -> Bool {
        if lockFD >= 0 { return true }
        let fd = open(folder.appendingPathComponent(".lock").path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return false }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 { close(fd); return false }
        lockFD = fd
        return true
    }

    static func loadAll() -> [(UUID, JobState)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { f in
            guard f.pathExtension == "json", let id = UUID(uuidString: f.deletingPathExtension().lastPathComponent),
                  let data = try? Data(contentsOf: f), let st = try? JSONDecoder().decode(JobState.self, from: data) else { return nil }
            return (id, st)
        }
    }
}

/// Mac notifications (only from the real app bundle: the notification center refuses a bare binary).
enum Notify {
    static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static func askOnce() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ title: String, _ body: String) {
        guard available else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

enum Power {
    /// True when the Mac is running on its battery (closing the lid would put it to sleep).
    static var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }
}

/// A plain-text log for one transfer: every step, pause, unplug, cancel and file problem, with times.
/// Written line by line as it happens to ~/Library/Logs/Clone Ranger, so a quit or crash still leaves
/// it showing how far things got. A copy goes next to the PDF report when the transfer ends.
final class TransferLog: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "Clone Ranger log")
    private let handle: FileHandle?
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static var folder: URL {
        let dir = ProcessInfo.processInfo.environment["CR_LOG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Clone Ranger")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init(name: String) {
        let f = DateFormatter()
        f.dateFormat = "yyMMdd-HHmmss"
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        url = Self.folder.appendingPathComponent("\(f.string(from: Date())) \(safe).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        Self.prune()
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        line("Clone Ranger \(v) · macOS \(os) · \(String(cString: model)) · \(ProcessInfo.processInfo.physicalMemory >> 30) GB memory")
    }

    deinit { try? handle?.close() }

    func line(_ text: String) {
        let s = "[\(Self.stamp.string(from: Date()))] \(text)\n"
        queue.async { [handle] in
            handle?.write(Data(s.utf8))
        }
    }

    /// Waits for everything logged so far to reach the disk.
    func flush() {
        queue.sync { [handle] in try? handle?.synchronize() }
    }

    /// A copy next to each PDF report ("100MEDIA 261105-1530 log.txt"). Never replaces anything.
    func copy(nextTo reports: [URL?]) {
        flush()
        for r in reports.compactMap({ $0 }) {
            let dst = r.deletingPathExtension().path + " log.txt"
            if !FS.exists(dst) { try? FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: dst)) }
        }
    }

    /// Keeps the newest 100 logs.
    private static func prune() {
        let fm = FileManager.default
        let logs = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in logs.dropFirst(100) { try? fm.removeItem(at: old) }
    }
}
