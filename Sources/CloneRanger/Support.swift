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

    static func save(_ t: Transfer) {
        guard let job = t.job else { return }
        let url = folder.appendingPathComponent(t.id.uuidString + ".json")
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(job.state) { try? data.write(to: url, options: .atomic) }
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
