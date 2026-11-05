import AppKit
import CRCore
import SwiftUI
import UniformTypeIdentifiers

/// Reads dropped Finder items as file URLs.
func dropped(_ providers: [NSItemProvider], _ handle: @escaping @MainActor (URL) -> Void) -> Bool {
    for p in providers where p.canLoadObject(ofClass: URL.self) {
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url { Task { @MainActor in handle(url) } }
        }
    }
    return true
}

/// Reads every dropped Finder item, then hands them over together (several clips dropped at once).
func droppedAll(_ providers: [NSItemProvider], _ handle: @escaping @MainActor ([URL]) -> Void) -> Bool {
    let group = DispatchGroup()
    let lock = NSLock()
    var urls: [(Int, URL)] = []
    for (i, p) in providers.enumerated() where p.canLoadObject(ofClass: URL.self) {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url { lock.withLock { urls.append((i, url)) } }
            group.leave()
        }
    }
    group.notify(queue: .main) {
        let ordered = urls.sorted { $0.0 < $1.0 }.map(\.1)
        MainActor.assumeIsolated { handle(ordered) }
    }
    return true
}

struct CenterColumn: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            topBar
            if let n = model.notice {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(T.amber)
                    Text(n).font(.system(size: 12.5)).foregroundStyle(T.label)
                    Spacer()
                    Button { model.notice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(T.label3)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: T.radius).fill(T.amber.opacity(0.14)))
            }
            if let t = model.selectedTransfer {
                TransferDetail(t: t)
            } else {
                if let id = model.justFinished, let t = model.transfers.first(where: { $0.id == id }) {
                    FinishedBanner(t: t)
                }
                Composer()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(T.bg)
    }

    /// One button at the top: start (or queue) what's been dropped below, or open a fresh drop area.
    @ViewBuilder private var topBar: some View {
        HStack(spacing: 10) {
            if model.selectedTransfer == nil {
                Button {
                    model.commit()
                } label: {
                    Label(model.busy ? "Add to Queue" : "Start Transfer", systemImage: model.busy ? "text.badge.plus" : "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle(large: true))
                .disabled(!model.draftReady)
                .keyboardShortcut(.return, modifiers: .command)
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundStyle(T.label3)
            } else {
                Button {
                    model.selected = nil
                } label: {
                    Label(model.busy ? "Queue Next" : "Start a Transfer", systemImage: "plus")
                }
                .buttonStyle(PrimaryButtonStyle(large: true))
                .keyboardShortcut("n", modifiers: .command)
                if model.busy {
                    Text(model.active.isEmpty ? "A transfer is stopped · new ones wait until it's resumed or stopped" : "A transfer is running · new ones wait in line")
                        .font(.system(size: 12))
                        .foregroundStyle(T.label3)
                }
            }
            Spacer()
        }
    }

    private var hint: String {
        if model.draftSource == nil { return "Drop a card, a folder, or some clips below to copy from" }
        if model.draftDests.isEmpty { return "Now drop where it should go" }
        if model.draftScanning { return "Counting files…" }
        if !model.draftReady { return "Fix the destination marked in red" }
        return model.busy ? "Waits until the current transfer is done" : "Ready"
    }
}

// MARK: - New transfer: what to copy on top, an arrow, where it goes underneath

struct Composer: View {
    @EnvironmentObject var model: AppModel
    @State private var sourceHover = false
    @State private var destHover = false

    var body: some View {
        if model.draftSource == nil && model.draftDests.isEmpty {
            // Nothing yet: two big drop areas filling the column.
            VStack(spacing: 0) {
                source.frame(maxHeight: 230)
                FlowArrow()
                destinations.frame(maxHeight: .infinity, alignment: .top)
            }
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    source
                    FlowArrow()
                    destinations
                }
                .padding(.bottom, 16)
            }
        }
    }

    // MARK: Copy from

    @ViewBuilder private var source: some View {
        Group {
            if let src = model.draftSource {
                Card {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        SectionLabel(text: "Copy from")
                        Text(Fmt.place(model.draftItems == nil ? src.deletingLastPathComponent() : src))
                            .font(.system(size: 12)).foregroundStyle(T.label3).lineLimit(1).truncationMode(.head)
                        Spacer()
                        Button { model.clearDraft() } label: { Text("Clear") }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(T.label3).help("Start over")
                    }
                    if let items = model.draftItems {
                        ForEach(items, id: \.self) { name in
                            SourceItemRow(name: name, stat: model.draftStats[name], counting: model.draftScanning && model.draftStats[name] == nil,
                                          isVolume: false) { model.removeSourceItem(name) }
                        }
                    } else {
                        let isVolume = (try? src.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true
                        SourceItemRow(name: Plan.sourceName(src), stat: model.draftStats[""], counting: model.draftScanning,
                                      isVolume: isVolume) { model.clearDraft() }
                    }
                    if let s = model.draftScan {
                        HStack {
                            Text("In all: \(Fmt.count(s.files, "file")) · \(Fmt.bytes(s.bytes))")
                                .foregroundStyle(T.label2)
                            if !s.problems.isEmpty {
                                Text("· \(s.problems.count) couldn't be read").foregroundStyle(T.red)
                            }
                        }
                        .font(.system(size: 12))
                    }
                    addMore(src)
                }
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(T.blue, lineWidth: sourceHover ? 2 : 0))
            } else {
                Ghost(icon: "sdcard", title: "Drop the card, folders, or clips to copy from",
                      detail: "Drop more from the same place to add them. A card or folder is recreated exactly, folders and all.",
                      hover: sourceHover, button: "Choose…") { model.chooseSource() }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $sourceHover) { droppedAll($0) { model.addSources($0) } }
    }

    @ViewBuilder private func addMore(_ src: URL) -> some View {
        let isVolume = model.draftItems == nil && (try? src.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true
        let from = Fmt.place(model.draftItems == nil ? src.deletingLastPathComponent() : src)
        Text(isVolume ? "A whole card copies everything on it. Clear it to pick folders from inside instead."
                      : "Drop more folders or clips from \(from) to add them")
            .font(.system(size: 12))
            .foregroundStyle(sourceHover ? T.label : T.label3)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(sourceHover ? T.blue.opacity(0.10) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(sourceHover ? T.blue : Color.white.opacity(0.16), style: StrokeStyle(lineWidth: 1.2, dash: [6, 4])))
    }

    // MARK: Copy to

    @ViewBuilder private var destinations: some View {
        Group {
            if model.draftDests.isEmpty {
                Ghost(icon: "externaldrive.badge.plus", title: "Drop the folders to copy to",
                      detail: "Up to \(AppModel.maxDestinations) drives, copied at the same time. A reports folder is made next to each copy.",
                      hover: destHover, button: "Choose…") { model.chooseDestinations() }
                    .frame(minHeight: 160)
            } else {
                Card {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        SectionLabel(text: "Copy to")
                        Text("\(model.draftDests.count) of \(AppModel.maxDestinations) drives, copied at the same time")
                            .font(.system(size: 12)).foregroundStyle(T.label3)
                    }
                    ForEach(model.draftDests, id: \.self) { d in DestDraftRow(url: d) }
                    if model.draftDests.count < AppModel.maxDestinations {
                        Ghost(icon: "externaldrive.badge.plus", title: "Drop another folder to copy to", detail: "",
                              hover: destHover, button: "Choose…", compact: true) { model.chooseDestinations() }
                            .frame(height: 70)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(T.blue, lineWidth: destHover ? 2 : 0))
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $destHover) { dropped($0) { model.addDestination($0) } }
    }
}

/// One thing under "copy from": a card, a folder or a file, with its size.
struct SourceItemRow: View {
    let name: String
    let stat: AppModel.ItemStat?
    let counting: Bool
    let isVolume: Bool
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isVolume ? "sdcard" : stat?.folder == false ? "doc" : "folder")
                .font(.system(size: 14)).foregroundStyle(isVolume ? T.amber : T.label2).frame(width: 20)
            Text(name).font(.system(size: 14, weight: .medium)).foregroundStyle(T.label)
                .lineLimit(1).truncationMode(.middle).layoutPriority(1)
            Spacer(minLength: 8)
            if let stat, !counting {
                Text(stat.folder ? "\(Fmt.count(stat.files, "file")) · \(Fmt.bytes(stat.bytes))" : Fmt.bytes(stat.bytes))
                    .font(.system(size: 12)).foregroundStyle(T.label3).lineLimit(1)
            } else {
                Text("Counting…").font(.system(size: 12)).foregroundStyle(T.label3)
            }
            Button(action: remove) { Image(systemName: "xmark") }
                .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(T.label3)
                .help("Take this off the list")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.035)))
    }
}

/// The line and down arrow between "copy from" and "copy to".
struct FlowArrow: View {
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(T.sepStrong).frame(width: 2, height: 12)
            Image(systemName: "arrow.down")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(T.label2)
                .frame(width: 30, height: 30)
                .background(Circle().fill(T.panel))
                .overlay(Circle().stroke(T.sepStrong, lineWidth: 1.5))
            Rectangle().fill(T.sepStrong).frame(width: 2, height: 12)
        }
        .frame(maxWidth: .infinity)
    }
}

/// One destination drive in the new-transfer area, and underneath it, top to bottom, what will land there.
struct DestDraftRow: View {
    @EnvironmentObject var model: AppModel
    let url: URL

    var body: some View {
        let problem = model.roomProblem(for: url)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: Plan.isLocal(url) ? "externaldrive" : "server.rack")
                    .font(.system(size: 15)).foregroundStyle(T.label2).frame(width: 22)
                Text(Fmt.volumeName(url)).font(.system(size: 14, weight: .semibold)).foregroundStyle(T.label)
                Text(Fmt.place(url, includeVolume: false)).font(.system(size: 12)).foregroundStyle(T.label3)
                    .lineLimit(1).truncationMode(.head)
                Spacer(minLength: 8)
                if let free = Plan.freeSpace(url) {
                    Text("\(Fmt.bytes(free)) free").font(.system(size: 11.5)).foregroundStyle(problem == nil ? T.label3 : T.red)
                }
                Button { model.removeDestination(url) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(T.label3).help("Remove")
            }
            if let problem {
                Text(problem).font(.system(size: 12, weight: .medium)).foregroundStyle(T.red).padding(.leading, 32)
            }
            if model.draftSource != nil {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(landing.prefix(14).enumerated()), id: \.offset) { _, leaf in
                        TreeLeaf(leaf: leaf)
                    }
                    if landing.count > 14 {
                        Text("and \(landing.count - 14) more").font(.system(size: 11.5)).foregroundStyle(T.label3)
                            .padding(.leading, 16).padding(.vertical, 3)
                    }
                }
                .padding(.leading, 20)
                .overlay(alignment: .leading) {
                    Rectangle().fill(T.sepStrong).frame(width: 1.5).padding(.leading, 20).padding(.bottom, 12)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.02)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.sep, lineWidth: 1))
    }

    /// What will be created in this folder, in order: each thing copied (with its new name if its own is
    /// taken), then the reports folder.
    private var landing: [TreeLeaf.Leaf] {
        guard let src = model.draftSource else { return [] }
        if let items = model.draftItems {
            var taken = Set<String>()
            var leaves: [TreeLeaf.Leaf] = items.map { name in
                let folder = model.draftStats[name]?.folder ?? true
                guard FS.exists(FS.join(url.path, name)) else {
                    return TreeLeaf.Leaf(name: name, folder: folder, note: folder ? "new folder" : "", clash: nil)
                }
                let other = Engine.freeName(name, in: url.path, taken: taken)
                taken.insert(other.lowercased())
                let why = folder ? "\(name) is already here: this copy will be named “\(other)”"
                    : "\(name) is already here: if it's identical it's left as it is, otherwise this copy is named “\(other)”"
                return TreeLeaf.Leaf(name: other, folder: folder, note: "", clash: why)
            }
            leaves.append(TreeLeaf.Leaf(name: Plan.sourceName(src) + " Reports", folder: true, note: "PDF report", clash: nil))
            return leaves
        }
        let name = Plan.targetName(for: src, in: url)
        let clash = name != Plan.sourceName(src) ? "\(Plan.sourceName(src)) is already here: this copy will be named “\(name)”" : nil
        return [TreeLeaf.Leaf(name: name, folder: true, note: clash == nil ? "new folder" : "", clash: clash),
                TreeLeaf.Leaf(name: name + " Reports", folder: true, note: "PDF report", clash: nil)]
    }
}

/// One line of a destination's tree.
struct TreeLeaf: View {
    struct Leaf { var name: String; var folder: Bool; var note: String; var clash: String? }
    let leaf: Leaf

    var body: some View {
        HStack(spacing: 7) {
            Rectangle().fill(T.sepStrong).frame(width: 11, height: 1.5)
            Image(systemName: leaf.folder ? "folder" : "doc").font(.system(size: 12)).foregroundStyle(T.label2)
            Text(leaf.name).font(.system(size: 13)).foregroundStyle(T.label).lineLimit(1).truncationMode(.middle)
            if let clash = leaf.clash {
                Text(clash).font(.system(size: 11.5, weight: .medium)).foregroundStyle(T.red).lineLimit(2)
            } else if !leaf.note.isEmpty {
                Text(leaf.note).font(.system(size: 11.5)).foregroundStyle(T.label3)
            }
        }
        .padding(.vertical, 3)
    }
}

/// Dashed "drop here" area.
struct Ghost: View {
    let icon: String
    let title: String
    let detail: String
    let hover: Bool
    let button: String
    var compact = false
    let action: () -> Void

    var body: some View {
        if compact {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 16, weight: .light)).foregroundStyle(hover ? T.blue : T.label3)
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(hover ? T.label : T.label2)
                Button(button, action: action).buttonStyle(SecondaryButtonStyle())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(hover ? T.blue.opacity(0.10) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(hover ? T.blue : Color.white.opacity(0.16), style: StrokeStyle(lineWidth: 1.2, dash: [6, 4])))
        } else {
            full
        }
    }

    private var full: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 30, weight: .light)).foregroundStyle(hover ? T.blue : T.label3)
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(hover ? T.label : T.label2)
            Text(detail).font(.system(size: 12)).foregroundStyle(T.label3).multilineTextAlignment(.center)
            Button(button, action: action).buttonStyle(SecondaryButtonStyle()).padding(.top, 2)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(hover ? T.blue.opacity(0.10) : T.fill2.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(hover ? T.blue : Color.white.opacity(0.2), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])))
    }
}

// MARK: - A transfer's details

struct TransferDetail: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var t: Transfer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                interruptedCard
                batteryWarning
                Card {
                    SectionLabel(text: "Copy from")
                    Text(t.selectionNote ?? t.displayName).font(.system(size: 17, weight: .semibold)).foregroundStyle(T.label)
                    Text(t.source.path).font(.system(size: 12, design: .monospaced)).foregroundStyle(T.label2)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Text("\(Fmt.count(t.totalFiles, "file")) · \(Fmt.bytes(t.totalBytes))")
                        .font(.system(size: 12.5)).foregroundStyle(T.label2)
                }
                FlowArrow().padding(.vertical, -6)
                Card {
                    SectionLabel(text: "Copy to · \(Fmt.count(t.parents.count, "destination"))")
                    ForEach(t.parents.indices, id: \.self) { d in
                        if d > 0 { Divider().overlay(T.sep) }
                        destRow(d)
                    }
                }
                stats
                if t.state.running, !t.snap.note.isEmpty {
                    Text(t.snap.note)
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(T.label)
                } else if t.state.running, !t.snap.current.isEmpty, t.state == .copying {
                    Text("Now: \(t.snap.current)")
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(T.label2)
                        .lineLimit(1).truncationMode(.middle)
                }
                problems
                recovered
                Text("Checksum: xxHash64. The source is read once; every copy is read back off its drive and compared.")
                    .font(.system(size: 11.5)).foregroundStyle(T.label3)
            }
            .padding(.bottom, 20)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(t.displayName).font(.system(size: 20, weight: .bold)).foregroundStyle(T.label)
            Pill(text: t.label, color: t.color)
            Spacer()
            if t.state.running {
                Button { model.togglePause(t) } label: {
                    Label(t.paused ? "Resume" : "Pause", systemImage: t.paused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(SecondaryButtonStyle(tint: T.orange))
                Button { model.cancel(t) } label: { Label("Cancel", systemImage: "xmark") }
                    .buttonStyle(SecondaryButtonStyle(tint: T.tan))
            } else if t.state == .queued {
                Button { model.moveQueued(t, up: true) } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(SecondaryButtonStyle()).help("Move up in the queue")
                Button { model.moveQueued(t, up: false) } label: { Image(systemName: "arrow.down") }
                    .buttonStyle(SecondaryButtonStyle()).help("Move down in the queue")
                Button { model.cancel(t) } label: { Label("Remove from Queue", systemImage: "xmark") }
                    .buttonStyle(SecondaryButtonStyle(tint: T.tan))
            }
        }
    }

    @ViewBuilder private func destRow(_ d: Int) -> some View {
        let parent = t.parents[d]
        let target = d < t.targets.count ? t.targets[d] : nil
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "externaldrive").font(.system(size: 18)).foregroundStyle(T.label2).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(t.volume(d)).font(.system(size: 14, weight: .semibold)).foregroundStyle(T.label)
                Text(Fmt.shortPath(target ?? parent)).font(.system(size: 12, design: .monospaced)).foregroundStyle(T.label2)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                if t.state.finished {
                    let s = t.destinationSummary(d)
                    Text(s.text).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(s.ok ? T.green : t.state == .canceled ? T.tan : T.red)
                    HStack(spacing: 8) {
                        if d < t.reports.count, let r = t.reports[d] {
                            Button("Open Report") { NSWorkspace.shared.open(r) }.buttonStyle(SecondaryButtonStyle())
                        }
                        if let target {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([target]) }
                                .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                    .padding(.top, 4)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                Bar(fraction: t.destinationFraction(d), color: barColor(d))
                    .frame(minWidth: 110, maxWidth: 230)
                Text(barText(d)).font(.system(size: 11.5)).foregroundStyle(T.label2)
            }
        }
        .padding(.vertical, 4)
    }

    private func barColor(_ d: Int) -> Color {
        if t.state.finished {
            return t.destinationSummary(d).ok ? T.green : t.state == .canceled ? T.tan : T.red
        }
        return t.paused ? T.orange : t.state == .interrupted ? T.orange
            : t.state == .verifying || t.state == .rechecking ? T.purple : T.blue
    }

    private func barText(_ d: Int) -> String {
        switch t.state {
        case .queued: return "Waiting"
        case .scanning: return t.snap.note.isEmpty ? "Starting…" : t.snap.note
        case .copying: return "Copied " + Fmt.partOf(d < t.snap.written.count ? t.snap.written[d] : 0, t.totalBytes)
        case .verifying: return "Verified " + Fmt.partOf(d < t.snap.verified.count ? t.snap.verified[d] : 0, t.totalBytes)
        case .retrying: return "Copying failed files again…"
        case .rechecking: return "Re-checking what was copied…"
        case .interrupted: return t.waitingFor.map { _ in FS.exists(t.parents[d].path) ? "Stopped" : "Unplugged" } ?? "Stopped"
        case .report: return "Writing report…"
        default: return ""
        }
    }

    private var stats: some View {
        let stage: (String, Color) = t.paused && t.state.running ? ("Paused", T.orange)
            : t.state == .copying || t.state == .scanning ? ("1 · Copying", T.blue)
            : t.state == .verifying ? ("2 · Verifying", T.purple)
            : t.state == .retrying ? ("3 · Retrying \(t.retryCount)", T.blue)
            : t.state == .rechecking ? ("Re-checking", T.purple)
            : t.state == .interrupted ? ("Stopped", T.orange)
            : (t.label, t.color)
        let filesDone = t.state == .verifying ? (t.snap.filesVerified.max() ?? 0) : t.snap.filesCopied
        return HStack(spacing: 10) {
            Stat(title: "Stage", value: stage.0, color: stage.1)
            Stat(title: t.state.finished ? "Average copy speed" : "Speed",
                 value: t.state.finished ? avgSpeed : t.speed > 0 && t.state.running ? Fmt.rate(t.speed) + filesRate : "—")
            Stat(title: "Files", value: t.state.finished || t.state == .queued ? t.totalFiles.formatted()
                 : "\(filesDone.formatted()) / \(t.totalFiles.formatted())")
            Stat(title: t.state.finished ? "Total time" : "Time left in stage",
                 value: t.state.finished ? Fmt.duration(t.elapsed) : t.secondsLeft.map { "~" + Fmt.duration($0) } ?? "—")
        }
    }

    private var avgSpeed: String {
        guard let o = t.outcome else { return "—" }
        let s = o.copyFinished.timeIntervalSince(o.copyStarted)
        return s > 0 ? Fmt.rate(Double(o.scan.bytes) / s) : "—"
    }

    @ViewBuilder private var problems: some View {
        if let o = t.outcome, t.state == .failed {
            let bad = o.results.filter { $0.errors.contains { $0 != nil } }
            Card {
                SectionLabel(text: "Problems")
                ForEach(Array(o.scan.problems.enumerated()), id: \.offset) { _, p in
                    Text("\(p.path): \(p.reason)").font(.system(size: 12)).foregroundStyle(T.red)
                }
                ForEach(bad.prefix(200), id: \.item.path) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.item.path).font(.system(size: 12, weight: .medium)).foregroundStyle(T.label)
                        ForEach(r.errors.indices, id: \.self) { i in
                            if let e = r.errors[i] {
                                Text("\(t.volume(i)): \(e)").font(.system(size: 11.5)).foregroundStyle(T.red)
                            }
                        }
                    }
                }
                if bad.count > 200 { Text("…and \(bad.count - 200) more in the report").font(.system(size: 12)).foregroundStyle(T.label2) }
                if bad.contains(where: { !$0.unverified.joined().isEmpty }) {
                    Text("Copies that failed their verify were moved to the Unverified folder, so the copy itself only holds verified files.")
                        .font(.system(size: 12)).foregroundStyle(T.label2)
                    unverifiedButtons
                }
            }
        }
        if let p = t.reportProblem {
            Text(p).font(.system(size: 12)).foregroundStyle(T.red)
        }
    }
}

extension TransferDetail {
    /// After an unplug (or a quit): what happened, and the ways to carry on.
    @ViewBuilder var interruptedCard: some View {
        if t.state == .interrupted, let job = t.job {
            let copied = t.outcome?.copiedBytes ?? job.state.results.reduce(0) { $0 + ($1.item.kind == .file && $1.copied.contains(true) ? $1.item.size : 0) }
            Card {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(T.orange)
                    Text(t.interruptedBy).font(.system(size: 15, weight: .semibold)).foregroundStyle(T.label)
                }
                Text(copied > 0
                     ? "\(Fmt.bytes(copied)) of \(Fmt.bytes(t.totalBytes)) was copied before it stopped. Nothing copied so far is lost, and nothing carries on until you choose."
                     : "Anything already on the destinations is checked before it's trusted, and the rest is copied. Nothing carries on until you choose.")
                    .font(.system(size: 12.5)).foregroundStyle(T.label2)
                if let w = t.waitingFor {
                    Text("Plug \(w) back in to continue.")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(T.orange)
                    HStack(spacing: 8) {
                        if FS.exists(t.source.path) {
                            ForEach(t.parents.indices.filter { !FS.exists(t.parents[$0].path) }, id: \.self) { d in
                                Button("Finish Without \(t.volume(d))") { model.finishWithout(t, d) }
                                    .buttonStyle(SecondaryButtonStyle())
                            }
                        }
                        Button("Stop Here") { model.stopHere(t) }.buttonStyle(SecondaryButtonStyle(tint: T.tan))
                    }
                } else {
                    let dst = job.destinationRecheckBytes
                    if job.sourceNeedsRecheck {
                        let full = job.recheckBytes(.full), quick = job.recheckBytes(.quick)
                        ResumeChoice(title: "Resume Safely", primary: true,
                                     detail: "Re-reads all \(Fmt.bytes(full)) already copied from \(t.displayName) and re-checks the copies · \(estimate(full, dst))") {
                            model.resume(t, .full)
                        }
                        ResumeChoice(title: "Quick Check & Resume", primary: false,
                                     detail: "Checks names, sizes and dates, plus a \(Fmt.bytes(quick)) sample from \(t.displayName), and re-checks the copies · \(estimate(quick, dst))") {
                            model.resume(t, .quick)
                        }
                    } else {
                        ResumeChoice(title: "Resume", primary: true,
                                     detail: "Re-checks the \(Fmt.bytes(dst)) already on the destinations, then copies the rest · \(estimate(0, dst))") {
                            model.resume(t, .full)
                        }
                    }
                    Button("Stop Here") { model.stopHere(t) }.buttonStyle(SecondaryButtonStyle(tint: T.tan))
                }
                firstAidNote
            }
        } else {
            firstAidNote
        }
    }

    /// Source and destinations are re-checked at the same time, so the slower of the two sets the time.
    private func estimate(_ src: Int64, _ dst: Int64) -> String {
        let speed = avgCopySpeed ?? 300_000_000
        let perDrive = Double(dst) / Double(max(1, t.parents.count))
        return "about " + Fmt.duration(max(Double(src), perDrive) / speed + 5)
    }

    /// "· 31 files/s" while it's working through lots of small files (where MB/s says little).
    private var filesRate: String {
        guard t.filesPerSecond >= 1, t.speed / t.filesPerSecond < 4_000_000 else { return "" }
        return " · \(Int(t.filesPerSecond)) files/s"
    }

    private var avgCopySpeed: Double? {
        guard let o = t.outcome, o.copiedBytes > 0 else { return nil }
        let s = o.copyFinished.timeIntervalSince(o.copyStarted)
        return s > 1 ? Double(o.copiedBytes) / s : nil
    }

    /// A drive yanked mid-write can have a damaged file index, not just a half-written file.
    @ViewBuilder var firstAidNote: some View {
        let yanked = (t.outcome?.events ?? []).filter { $0.bad && $0.text.contains("disappeared") && !$0.text.hasPrefix(t.displayName) }
        if !yanked.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "stethoscope").foregroundStyle(T.amber)
                Text("A destination drive was unplugged while it was being written. Before trusting that drive, run First Aid on it in Disk Utility.")
                    .font(.system(size: 12)).foregroundStyle(T.label2)
                Spacer()
                Button("Open Disk Utility") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app"))
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    @ViewBuilder var batteryWarning: some View {
        if t.state.running && Power.onBattery {
            HStack(spacing: 8) {
                Image(systemName: "battery.50").foregroundStyle(T.amber)
                Text("Running on battery. Closing the lid will put the Mac to sleep and stop the transfer; plug in power for long transfers.")
                    .font(.system(size: 12)).foregroundStyle(T.label2)
            }
        }
    }

    /// "Show CLIP Unverified" for each destination that has one.
    @ViewBuilder var unverifiedButtons: some View {
        HStack(spacing: 8) {
            ForEach(t.targetPaths.indices, id: \.self) { d in
                let folder = t.job?.unverifiedFolder(d) ?? Engine.unverifiedFolder(forTarget: t.targetPaths[d])
                if FS.exists(folder) {
                    Button("Show \((folder as NSString).lastPathComponent) on \(t.volume(d))") {
                        NSWorkspace.shared.activateFileViewerSelecting([ReportWriter.exactURL(folder)])
                    }
                    .buttonStyle(SecondaryButtonStyle(tint: T.amber))
                }
            }
        }
    }

    /// Files that failed the first time, were copied again and now match.
    @ViewBuilder var recovered: some View {
        if let o = t.outcome {
            let again = o.results.filter { r in r.retried.contains(true) && !r.errors.contains { $0 != nil } }
            if !again.isEmpty {
                Card {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(T.amber)
                        SectionLabel(text: "Needed a second copy · now verified")
                    }
                    Text("These failed the first time. The bad copy was moved to the Unverified folder next to the copy, then just these files were copied again from the source and read back. They match now and are where they belong. Delete the Unverified folder once you've looked.")
                        .font(.system(size: 12)).foregroundStyle(T.label2)
                    unverifiedButtons
                    ForEach(again.prefix(100), id: \.item.path) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.item.path).font(.system(size: 12, weight: .medium)).foregroundStyle(T.label)
                            ForEach(r.firstError.indices, id: \.self) { i in
                                if let e = r.firstError[i] {
                                    Text("\(t.volume(i)) first try: \(e)").font(.system(size: 11.5)).foregroundStyle(T.amber)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// A big resume button with a line saying what it will do and how long it should take.
struct ResumeChoice: View {
    let title: String
    let primary: Bool
    let detail: String
    let action: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            if primary {
                Button(action: action) { Label(title, systemImage: "play.fill").frame(minWidth: 190) }
                    .buttonStyle(PrimaryButtonStyle(large: true))
            } else {
                Button(action: action) { Label(title, systemImage: "hare").frame(minWidth: 190) }
                    .buttonStyle(SecondaryButtonStyle())
            }
            Text(detail).font(.system(size: 12)).foregroundStyle(T.label2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

struct Stat: View {
    let title: String
    let value: String
    var color: Color = T.label
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(T.label3)
            Text(value).font(.system(size: 17, weight: .semibold)).foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: T.radius).fill(T.fill))
    }
}

/// Shown over a fresh new-transfer area right after a transfer ends: how it went, with a way back to it.
struct FinishedBanner: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var t: Transfer

    var body: some View {
        let color = t.state == .verified ? T.green : t.state == .canceled ? T.tan : T.red
        HStack(spacing: 10) {
            Image(systemName: t.state == .verified ? "checkmark.circle.fill" : t.state == .canceled ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(color)
            Text(headline).font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
            Text(detail).font(.system(size: 12.5)).foregroundStyle(T.label2).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            Button("View details") { model.selected = t.id }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(T.label)
            if let r = t.reports.compactMap({ $0 }).first {
                Button("Open report") { NSWorkspace.shared.open(r) }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(T.label)
            }
            Button { model.justFinished = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(T.label3)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.13)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.45), lineWidth: 1))
    }

    private var headline: String {
        switch t.state {
        case .verified: return "\(t.displayName) finished and verified"
        case .canceled: return "\(t.displayName) was canceled"
        default: return "\(t.displayName) finished with problems"
        }
    }

    private var detail: String {
        var parts = [Fmt.count(t.totalFiles, "file"), Fmt.bytes(t.totalBytes), Fmt.count(t.parents.count, "drive")]
        if t.state == .failed, let n = t.outcome?.failedCount, n > 0 { parts.append("\(Fmt.count(n, "file")) failed: see details") }
        else if t.reports.contains(where: { $0 != nil }) { parts.append("reports saved") }
        return "· " + parts.joined(separator: " · ")
    }
}
