import AppKit
import SwiftUI

/// A place in the left column: a drive or a shortcut folder.
struct Place: Identifiable, Hashable {
    enum Kind { case home, system, card, external, network }
    var url: URL
    var name: String
    var kind: Kind
    var free: Int64?
    var total: Int64?
    var id: String { url.path }

    var icon: String {
        switch kind {
        case .home: "folder"
        case .system: "internaldrive"
        case .card: "sdcard"
        case .external: "externaldrive"
        case .network: "server.rack"
        }
    }
}

@MainActor
final class Places: ObservableObject {
    @Published var home: [Place] = []
    @Published var drives: [Place] = []
    @Published var network: [Place] = []
    private var observers: [NSObjectProtocol] = []

    init() {
        reload()
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            })
        }
        // Free space changes as things copy.
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func reload() {
        let fm = FileManager.default
        let homeURL = fm.homeDirectoryForCurrentUser
        var h = [Place(url: homeURL, name: NSUserName(), kind: .home)]
        for (dir, name) in [(FileManager.SearchPathDirectory.desktopDirectory, "Desktop"), (.documentDirectory, "Documents"),
                            (.moviesDirectory, "Movies"), (.downloadsDirectory, "Downloads")] {
            if let u = fm.urls(for: dir, in: .userDomainMask).first { h.append(Place(url: u, name: name, kind: .home)) }
        }
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsLocalKey,
                                      .volumeIsInternalKey, .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeAvailableCapacityKey, .volumeTotalCapacityKey, .volumeIsBrowsableKey]
        var d: [Place] = [], n: [Place] = []
        for u in fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable != false else { continue }
            let free = v.volumeAvailableCapacityForImportantUsage.flatMap { $0 > 0 ? $0 : nil } ?? v.volumeAvailableCapacity.map(Int64.init)
            var p = Place(url: u, name: v.volumeLocalizedName ?? u.lastPathComponent, kind: .external,
                          free: free, total: v.volumeTotalCapacity.map(Int64.init))
            if u.path == "/" { p.kind = .system; p.name = v.volumeLocalizedName ?? "Macintosh HD"; d.insert(p, at: 0); continue }
            if v.volumeIsLocal == false { p.kind = .network; n.append(p); continue }
            if v.volumeIsInternal == true && v.volumeIsEjectable != true { p.kind = .system }
            else if v.volumeIsRemovable == true || looksLikeCard(u) { p.kind = .card }
            d.append(p)
        }
        if home != h { home = h }
        if drives != d { drives = d }
        if network != n { network = n }
    }

    /// Camera cards have a DCIM, PRIVATE, CLIP, XDROOT or similar folder at the top.
    private func looksLikeCard(_ u: URL) -> Bool {
        let names = Set(((try? FileManager.default.contentsOfDirectory(atPath: u.path)) ?? []).map { $0.uppercased() })
        return !names.isDisjoint(with: ["DCIM", "PRIVATE", "CLIP", "XDROOT", "M4ROOT", "CONTENTS", "AVCHD", "MISC"])
    }
}

struct Sidebar: View {
    @EnvironmentObject var places: Places
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                group("This Mac", places.home)
                group("Drives and cards", places.drives)
                if !places.network.isEmpty { group("Network", places.network) }
                Text("Drag a drive or folder into the middle, or right-click it.")
                    .font(.system(size: 11))
                    .foregroundStyle(T.label3)
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
            }
            .padding(.vertical, 10)
        }
        .background(T.side)
    }

    @ViewBuilder private func group(_ title: String, _ items: [Place]) -> some View {
        SectionLabel(text: title)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)
        ForEach(items) { p in
            FolderRow(url: p.url, name: p.name, icon: p.icon, depth: 0, place: p)
        }
    }
}

/// A folder in the left column that opens to show the folders inside it.
struct FolderRow: View {
    @EnvironmentObject var model: AppModel
    let url: URL
    let name: String
    let icon: String
    let depth: Int
    var place: Place?
    @State private var open = false
    @State private var children: [URL]?
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(T.label3)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 12)
                    .contentShape(Rectangle())
                    .onTapGesture { toggle() }
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(place?.kind == .card ? T.amber : T.label2)
                    .frame(width: 18)
                Text(name)
                    .font(.system(size: 13, weight: depth == 0 ? .medium : .regular))
                    .foregroundStyle(T.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)   // the name wins over the free-space label when space is tight
                Spacer(minLength: 4)
                if let free = place?.free, place?.kind != .home {
                    Text("\(Fmt.bytes(free)) free")
                        .font(.system(size: 10.5))
                        .foregroundStyle(T.label3)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 10 + CGFloat(depth) * 14)
            .padding(.trailing, 12)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(hover ? T.fill2 : .clear).padding(.horizontal, 6))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture(count: 2) { toggle() }
            .onDrag { NSItemProvider(object: url as NSURL) }
            .contextMenu {
                Button("Copy From Here") { model.setSource(url) }
                Button("Add as Destination") { model.addDestination(url) }
                Divider()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            .help(url.path)

            if let place, let free = place.free, let total = place.total, total > 0, place.kind != .home {
                Bar(fraction: 1 - Double(free) / Double(total), color: T.label3, height: 3)
                    .padding(.leading, 46).padding(.trailing, 14).padding(.bottom, 4)
            }

            if open {
                if let children, !children.isEmpty {
                    ForEach(children, id: \.self) { c in
                        FolderRow(url: c, name: c.lastPathComponent, icon: "folder", depth: depth + 1)
                    }
                } else if children != nil {
                    Text("No folders inside")
                        .font(.system(size: 11))
                        .foregroundStyle(T.label3)
                        .padding(.leading, 46 + CGFloat(depth) * 14)
                        .padding(.vertical, 2)
                }
            }
        }
    }

    private func toggle() {
        withAnimation(.easeOut(duration: 0.12)) { open.toggle() }
        if open {
            let u = url
            Task.detached {
                let kids = ((try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                                         options: [.skipsHiddenFiles])) ?? [])
                    .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                await MainActor.run { children = kids }
            }
        }
    }
}
