import AppKit
import Combine
import CRCore
import SwiftUI

enum TState: Equatable {
    case queued, scanning, copying, verifying, retrying, rechecking, report, interrupted, verified, failed, canceled

    var running: Bool { [.scanning, .copying, .verifying, .retrying, .rechecking, .report].contains(self) }
    var finished: Bool { [.verified, .failed, .canceled].contains(self) }
}

/// One transfer: a source folder copied into up to four destination folders.
@MainActor
final class Transfer: ObservableObject, Identifiable {
    let id: UUID
    let source: URL
    let sourceName: String
    let parents: [URL]                       // the folders dropped as destinations
    @Published var targets: [URL] = []       // the new "CLIP" / "CLIP 2" folders inside them (for showing)
    var targetPaths: [String] = []           // the same, byte-exact names (see FS)
    @Published var state: TState = .queued
    @Published var paused = false
    @Published var snap = TransferProgress.Snapshot()
    @Published var totalBytes: Int64
    @Published var totalFiles: Int
    @Published var speed: Double = 0         // bytes per second, current stage
    @Published var retryCount = 0            // files being copied again after failing the first time
    @Published var outcome: TransferOutcome?
    @Published var reports: [URL?] = []      // PDF per destination
    @Published var reportProblem: String?
    @Published var waitingFor: String?       // interrupted: what still needs plugging back in
    @Published var interruptedBy = ""        // "A001 was unplugged" / "Clone Ranger quit before this finished"
    var job: TransferJob?
    var created = Date()
    var started: Date?
    var stageStarted: Date?
    var finished: Date?
    let control = JobControl()
    var progress: TransferProgress?
    private var samples: [(Date, Int64)] = []

    init(source: URL, parents: [URL], bytes: Int64, files: Int, id: UUID = UUID()) {
        self.id = id
        self.source = source
        self.sourceName = Plan.sourceName(source)
        self.parents = parents
        self.totalBytes = bytes
        self.totalFiles = files
    }

    /// Rebuilt from a progress file left by a transfer that didn't finish (Clone Ranger quit or crashed).
    convenience init(unfinished st: JobState, id: UUID) {
        let parents = st.targets.map { URL(fileURLWithPath: ($0 as NSString).deletingLastPathComponent) }
        self.init(source: URL(fileURLWithPath: st.source), parents: parents, bytes: st.scan.bytes, files: st.scan.files, id: id)
        targetPaths = st.targets
        targets = st.targets.map { URL(fileURLWithPath: $0) }
        started = st.copyStarted
        created = st.copyStarted
        let progress = TransferProgress(destinations: st.targets.count)
        self.progress = progress
        job = TransferJob(state: st, control: control, progress: progress) { _ in }
        state = .interrupted
        interruptedBy = "Clone Ranger quit before this finished"
    }

    var displayName: String { job?.sourceName ?? sourceName }
    func volume(_ d: Int) -> String { job?.targetVolumes[d] ?? Fmt.volumeName(parents[d]) }

    /// What the colored pill and fill bar show.
    var color: Color {
        if paused && state.running { return T.orange }
        switch state {
        case .queued: return T.label3
        case .scanning, .copying: return T.blue
        case .verifying, .report, .rechecking: return T.purple
        case .retrying: return T.blue
        case .interrupted: return T.orange
        case .verified: return T.green
        case .failed: return T.red
        case .canceled: return T.tan
        }
    }

    var label: String {
        if paused && state.running { return "Paused" }
        switch state {
        case .queued: return "Queued"
        case .scanning: return "Starting"
        case .copying: return "Copying"
        case .verifying: return "Verifying"
        case .retrying: return "Retrying \(retryCount)"
        case .rechecking: return "Re-checking"
        case .interrupted: return waitingFor != nil ? "Unplugged" : "Ready to resume"
        case .report: return "Writing report"
        case .verified: return "✓ Verified"
        case .failed:
            let n = outcome?.failedCount ?? 0
            return n > 0 ? "\(n) failed" : "Failed"
        case .canceled: return "Canceled"
        }
    }

    /// Destinations that are actually being written (not refused up front).
    var liveCount: Int {
        let problems = outcome?.destinationProblems ?? []
        return max(1, parents.indices.filter { $0 >= problems.count || problems[$0] == nil }.count)
    }

    /// 0…1 for the current stage.
    var fraction: Double {
        guard totalBytes > 0 else { return state.finished || state == .verifying ? 1 : 0 }
        switch state {
        case .copying, .scanning: return Double(snap.read) / Double(totalBytes)
        case .verifying: return Double(snap.verified.reduce(0, +)) / Double(totalBytes * Int64(liveCount))
        case .rechecking:
            let total = snap.recheckSourceTotal + snap.recheckDestTotal
            return total > 0 ? Double(snap.recheckSourceDone + snap.recheckDestDone) / Double(total) : 0
        case .interrupted: return outcome.map { Double($0.copiedBytes) / Double(totalBytes) } ?? 0
        case .queued: return 0
        default: return 1
        }
    }

    /// Bytes done / total for one destination in the current stage.
    func destinationFraction(_ d: Int) -> Double {
        guard totalBytes > 0 else { return state.finished ? 1 : 0 }
        switch state {
        case .copying, .scanning: return d < snap.written.count ? Double(snap.written[d]) / Double(totalBytes) : 0
        case .verifying: return d < snap.verified.count ? Double(snap.verified[d]) / Double(totalBytes) : 0
        case .rechecking, .interrupted: return fraction
        case .queued: return 0
        default: return 1
        }
    }

    var secondsLeft: Double? {
        guard speed > 1, state == .copying || state == .verifying else { return nil }
        let total = Double(totalBytes) * (state == .verifying ? Double(liveCount) : 1)
        return max(0, total * (1 - fraction) / speed)
    }

    var elapsed: Double {
        guard let started else { return 0 }
        return (finished ?? Date()).timeIntervalSince(started)
    }

    /// Called a few times a second while running.
    func tick() {
        guard let progress, state.running else { return }
        snap = progress.snapshot
        let bytes = state == .verifying ? snap.verified.reduce(0, +)
            : state == .rechecking ? snap.recheckSourceDone + snap.recheckDestDone : snap.read
        let now = Date()
        if paused { samples.removeAll(); speed = 0; return }
        samples.append((now, bytes))
        samples.removeAll { now.timeIntervalSince($0.0) > 3 }
        if let first = samples.first, now.timeIntervalSince(first.0) > 0.4 {
            speed = Double(bytes - first.1) / now.timeIntervalSince(first.0)
        }
    }

    func stageChanged() { samples.removeAll(); speed = 0; stageStarted = Date() }

    /// Per-destination status after the transfer.
    func destinationSummary(_ d: Int) -> (ok: Bool, text: String) {
        guard let o = outcome else { return (false, "") }
        if d < o.destinationProblems.count, let p = o.destinationProblems[d] { return (false, p) }
        let bad = o.results.filter { $0.errors[d] != nil }.count
        if bad > 0 { return (false, o.canceled ? "Canceled · \(Fmt.count(bad, "file")) not done" : "\(Fmt.count(bad, "file")) failed") }
        let again = o.results.filter { $0.retried[d] }.count
        return (true, "All \(Fmt.count(o.scan.files, "file")) verified" + (again > 0 ? " · \(again) needed a second copy" : ""))
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var transfers: [Transfer] = []
    @Published var selected: UUID?           // nil = the new-transfer area is showing
    @Published var draftSource: URL?
    @Published var draftDests: [URL] = []
    @Published var draftScan: ScanResult?
    @Published var draftScanning = false
    @Published var notice: String?
    @AppStorage("transfersAtOnce") var transfersAtOnce = 1
    @AppStorage("saveCSV") var saveCSV = false
    @AppStorage("largeReportFrames") var largeReportFrames = false

    static let maxDestinations = 4
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var reserved: [String: Set<String>] = [:]   // parent path → names being created right now
    private var saveCountdown = 20

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickAll() }
        }
    }

    var active: [Transfer] { transfers.filter { $0.state.running } }
    var interrupted: [Transfer] { transfers.filter { $0.state == .interrupted } }
    var queued: [Transfer] { transfers.filter { $0.state == .queued } }
    var history: [Transfer] {
        transfers.filter { $0.state.finished }.sorted { ($0.finished ?? $0.created) > ($1.finished ?? $1.created) }
    }
    /// Something is running or waiting to be resumed (new transfers queue behind it).
    var busy: Bool { !active.isEmpty || !interrupted.isEmpty }
    private var watchers: [UUID: AnyCancellable] = [:]

    /// The lists (active / stopped / queued / history) regroup whenever a transfer changes state.
    private func watch(_ t: Transfer) {
        watchers[t.id] = t.$state.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }
    }
    var selectedTransfer: Transfer? { transfers.first { $0.id == selected } }

    private func tickAll() {
        for t in active { t.tick() }
        for t in interrupted {
            let w = t.job?.waitingFor()
            if w == nil && t.waitingFor != nil {
                Notify.post("\(t.displayName) is back", "Choose how to resume in Clone Ranger.")
            }
            if w != t.waitingFor { t.waitingFor = w }
        }
        NSApp.dockTile.badgeLabel = active.isEmpty && interrupted.isEmpty ? nil : "\(active.count + queued.count + interrupted.count)"
        saveCountdown -= 1
        if saveCountdown <= 0 {
            saveCountdown = 20   // every 5 s
            for t in active where t.state != .report { Journal.save(t) }
        }
    }

    // MARK: New transfer

    func setSource(_ url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            notice = "Drop a folder or a card to copy from (\(url.lastPathComponent) isn't a folder)."
            return
        }
        notice = nil
        selected = nil
        draftSource = url
        draftDests.removeAll { Plan.problem(source: url, destination: $0, others: []) != nil }
        draftScan = nil
        draftScanning = true
        Task.detached(priority: .userInitiated) {
            let scan = Scanner.scan(url)
            await MainActor.run {
                guard self.draftSource == url else { return }
                self.draftScan = scan
                self.draftScanning = false
            }
        }
    }

    func addDestination(_ url: URL) {
        selected = nil
        guard draftDests.count < Self.maxDestinations else {
            notice = "Up to \(Self.maxDestinations) destinations per transfer."
            return
        }
        if let p = Plan.problem(source: draftSource, destination: url, others: draftDests) {
            notice = "\(url.lastPathComponent): \(p)."
            return
        }
        notice = nil
        draftDests.append(url)
    }

    func removeDestination(_ url: URL) { draftDests.removeAll { $0 == url } }

    func clearDraft() {
        draftSource = nil; draftDests = []; draftScan = nil; draftScanning = false; notice = nil
    }

    /// Bytes this draft would put on each destination's drive, counting other destinations on the same drive.
    func roomProblem(for dest: URL) -> String? {
        guard let bytes = draftScan?.bytes, let free = Plan.freeSpace(dest) else { return nil }
        let vol = Fmt.volumeName(dest)
        let onSameDrive = draftDests.filter { Fmt.volumeName($0) == vol }.count
        let need = bytes * Int64(onSameDrive)
        return free < need ? "Not enough room: needs \(Fmt.bytes(need)), \(Fmt.bytes(free)) free" : nil
    }

    var draftReady: Bool {
        draftSource != nil && !draftDests.isEmpty && draftScan != nil && draftDests.allSatisfy { roomProblem(for: $0) == nil }
    }

    func commit() {
        guard draftReady, let src = draftSource, let scan = draftScan else { return }
        let t = Transfer(source: src, parents: draftDests, bytes: scan.bytes, files: scan.files)
        watch(t)
        transfers.append(t)
        selected = t.id
        clearDraft()
        pump()
    }

    // MARK: Running

    /// Starts queued transfers, oldest first, up to the "transfers at once" setting. An unplugged transfer
    /// keeps its place, so the queue waits until it's resumed or stopped.
    func pump() {
        while active.count + interrupted.count < max(1, transfersAtOnce), let next = queued.first { start(next) }
        if active.isEmpty, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        } else if !active.isEmpty, activity == nil {
            // Keep the Mac awake for long overnight offloads.
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                             reason: "Copying and verifying files")
        }
    }

    private func start(_ t: Transfer) {
        // Pick "CLIP" / "CLIP 2"… now, not when queued, so earlier transfers' folders are seen.
        t.targetPaths = t.parents.map { p in
            let name = Plan.targetName(for: t.source, in: p, also: reserved[p.path] ?? [])
            reserved[p.path, default: []].insert(name.lowercased())
            return FS.join(p.path, name)
        }
        t.targets = t.targetPaths.map { URL(fileURLWithPath: $0) }
        let progress = TransferProgress(destinations: t.parents.count)
        t.progress = progress
        t.started = Date()
        t.state = .scanning
        t.stageChanged()
        let job = TransferJob(source: t.source.path, targets: t.targetPaths, control: t.control, progress: progress,
                              stage: stageHandler(t))
        t.job = job
        Notify.askOnce()
        run(t) { $0.start() }
    }

    private func stageHandler(_ t: Transfer) -> @Sendable (Stage) -> Void {
        { stage in
            Task { @MainActor in
                switch stage {
                case .scanning: t.state = .scanning
                case .copying: t.state = .copying
                case .verifying: t.state = .verifying
                case .retrying(let n): t.state = .retrying; t.retryCount = n
                case .rechecking: t.state = .rechecking
                case .writingReport, .done: break
                }
                t.stageChanged()
                if case .scanning = stage {} else { Journal.save(t) }   // a crash from here on can be resumed
            }
        }
    }

    /// Runs (or resumes) a transfer's job off the main thread, then wraps up.
    private func run(_ t: Transfer, _ work: @escaping @Sendable (TransferJob) -> TransferOutcome) {
        guard let job = t.job else { return }
        pump()
        Task.detached(priority: .userInitiated) {
            let outcome = work(job)
            await self.complete(t, outcome)
        }
    }

    private func complete(_ t: Transfer, _ outcome: TransferOutcome) async {
        t.snap = t.progress?.snapshot ?? t.snap
        t.outcome = outcome
        t.totalBytes = outcome.scan.bytes
        t.totalFiles = outcome.scan.files
        t.paused = false
        t.control.paused = false
        t.speed = 0

        if outcome.interrupted {
            // Wait for the card or drive to come back; the person decides how to resume.
            t.state = .interrupted
            t.waitingFor = t.job?.waitingFor()
            t.interruptedBy = outcome.events.last(where: \.bad)?.text ?? "Something was unplugged"
            Journal.save(t)
            Notify.post("\(t.displayName) stopped", "\(t.interruptedBy). Plug it back in, then choose how to resume. Nothing copied so far is lost.")
            NSSound(named: "Basso")?.play()
            if !NSApp.isActive { NSApp.requestUserAttention(.criticalRequest) }
            pump()
            return
        }

        t.state = .report
        t.stageChanged()
        let data = ReportData(t)
        let csv = saveCSV, compact = !largeReportFrames && ProcessInfo.processInfo.environment["CR_LARGE_FRAMES"] == nil
        let (reports, problem) = await Task.detached { await ReportWriter.writeAll(data, csv: csv, compactClips: compact) }.value
        t.reports = reports
        t.reportProblem = problem
        t.finished = Date()
        t.state = outcome.canceled ? .canceled : outcome.failedCount > 0 || outcome.fatal != nil ? .failed : .verified
        for (p, target) in zip(t.parents, t.targetPaths) { reserved[p.path]?.remove((target as NSString).lastPathComponent.lowercased()) }
        Journal.remove(t)
        pump()
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        NSSound(named: t.state == .verified ? "Glass" : "Basso")?.play()
        Notify.post("\(t.displayName): \(t.label)", t.state == .verified ? "Every file was read back and matches." : "Open Clone Ranger for details.")
    }

    // MARK: After an unplug

    func resume(_ t: Transfer, _ mode: ResumeMode) {
        guard t.state == .interrupted, t.waitingFor == nil else { return }
        t.state = .rechecking
        t.stageChanged()
        t.job?.stage = stageHandler(t)
        run(t) { $0.resume(mode) }
    }

    /// Carries on without a destination that isn't coming back.
    func finishWithout(_ t: Transfer, _ d: Int) {
        let a = NSAlert()
        a.messageText = "Finish without \(t.volume(d))?"
        a.informativeText = "The other drives get everything. \(t.volume(d)) keeps what it has, but it won't be verified or finished, and the report marks it incomplete."
        a.addButton(withTitle: "Finish Without It")
        a.addButton(withTitle: "Keep Waiting")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        guard let job = t.job else { return }
        if job.waitingFor() != nil && !FS.exists(t.source.path) { return }
        t.state = .rechecking
        t.stageChanged()
        job.stage = stageHandler(t)
        run(t) { $0.resume(.full, leaveOut: [d]) }
    }

    func stopHere(_ t: Transfer) {
        let a = NSAlert()
        a.messageText = "Stop \(t.displayName) here?"
        a.informativeText = "What was copied stays where it is, but files copied before the stop aren't verified. The report lists what didn't finish."
        a.addButton(withTitle: "Stop Here")
        a.addButton(withTitle: "Keep Waiting")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        t.state = .report
        run(t) { $0.giveUp() }
    }

    /// Transfers left unfinished last time Clone Ranger ran.
    func loadUnfinished() {
        for (id, st) in Journal.loadAll() where !transfers.contains(where: { $0.id == id }) {
            let t = Transfer(unfinished: st, id: id)
            t.waitingFor = t.job?.waitingFor()
            for (p, target) in zip(t.parents, t.targetPaths) { reserved[p.path, default: []].insert((target as NSString).lastPathComponent.lowercased()) }
            watch(t)
            transfers.append(t)
            selected = selected ?? t.id
        }
    }

    func togglePause(_ t: Transfer) {
        t.paused.toggle()
        t.control.paused = t.paused
    }

    func cancel(_ t: Transfer) {
        if t.state == .interrupted { stopHere(t); return }
        if t.state == .queued {
            transfers.removeAll { $0.id == t.id }
            if selected == t.id { selected = nil }
            return
        }
        let a = NSAlert()
        a.messageText = "Cancel \(t.displayName)?"
        a.informativeText = "Files already copied stay where they are. The transfer is marked canceled and the report says what didn't finish. Nothing on the source is touched."
        a.addButton(withTitle: "Cancel Transfer")
        a.addButton(withTitle: "Keep Going")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        t.control.cancelled = true
        t.control.paused = false
    }

    func moveQueued(_ t: Transfer, up: Bool) {
        let q = queued
        guard let i = q.firstIndex(where: { $0.id == t.id }) else { return }
        let j = up ? i - 1 : i + 1
        guard q.indices.contains(j), let a = transfers.firstIndex(where: { $0.id == q[i].id }),
              let b = transfers.firstIndex(where: { $0.id == q[j].id }) else { return }
        transfers.swapAt(a, b)
    }

    // MARK: Choose with a panel (for people who'd rather click than drag)

    func chooseSource() {
        if let u = pick(prompt: "Copy From", multiple: false).first { setSource(u) }
    }

    func chooseDestinations() {
        for u in pick(prompt: "Copy To", multiple: true) { addDestination(u) }
    }

    private func pick(prompt: String, multiple: Bool) -> [URL] {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.allowsMultipleSelection = multiple
        p.prompt = prompt
        return p.runModal() == .OK ? p.urls : []
    }
}
