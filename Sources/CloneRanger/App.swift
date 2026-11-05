import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            
            guard let m = model, m.busy || !m.queued.isEmpty, ProcessInfo.processInfo.environment["CR_AUTOPLAY"] == nil else {
                return .terminateNow
            }
            let alert = NSAlert()
            alert.messageText = "A transfer is still running."
            alert.informativeText = "Quitting stops it and clears the queue. Next time you open Clone Ranger it offers to pick up where it left off, after re-checking the card and what was copied. Nothing on the source is touched."
            alert.addButton(withTitle: "Keep Running")
            alert.addButton(withTitle: "Quit")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
            for t in m.active where t.state != .report {
                t.log?.line("Clone Ranger was quit while this was running. It can be picked back up next time it opens.")
                t.log?.flush()
                Journal.saveNow(t)
            }
            return .terminateNow
        }
    }
}

struct CloneRangerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @StateObject private var places = Places()

    var body: some Scene {
        Window("Clone Ranger", id: "main") {
            RootView()
                .environmentObject(model)
                .environmentObject(places)
                .frame(minWidth: 1000, minHeight: 640)
                .onAppear {
                    delegate.model = model
                    model.loadUnfinished()
                    Autoplay.startIfAsked(model: model)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1380, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Transfer") { model.selected = nil }.keyboardShortcut("n")
                Divider()
                Button("Choose Source…") { model.chooseSource() }.keyboardShortcut("o")
                Button("Add Destination…") { model.chooseDestinations() }.keyboardShortcut("d")
            }
            CommandGroup(after: .help) {
                Button("Show Logs") { NSWorkspace.shared.open(TransferLog.folder) }
            }
        }

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            // Side columns give up width in proportion as the window narrows (down to a minimum), so
            // nothing overlaps; the middle keeps the rest.
            GeometryReader { g in
                let left = min(260, max(200, g.size.width * 0.19))
                let right = min(370, max(290, g.size.width * 0.27))
                HStack(spacing: 0) {
                    Sidebar().frame(width: left)
                    Groove()
                    CenterColumn().frame(maxWidth: .infinity)
                    Groove()
                    RightColumn().frame(width: right)
                }
                .frame(width: g.size.width, height: g.size.height)
            }
        }
        .background(T.bg)
        .preferredColorScheme(.dark)
    }
}

/// Across the top: the mark and the name.
struct TopBar: View {
    var body: some View {
        HStack(spacing: 10) {
            Spacer()
            LogoMark(width: 38)
            Text("Clone Ranger")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(T.label)
            Spacer()
        }
        .overlay(alignment: .trailing) {
            SettingsLink { Image(systemName: "gearshape") }
                .buttonStyle(.plain)
                .foregroundStyle(T.label2)
                .help("Settings")
                .padding(.trailing, 16)
        }
        .frame(height: 50)
        .frame(maxWidth: .infinity)
        // Bevelled: a light top lip, a shaded face, a dark bottom edge and a soft shadow onto the columns.
        .background(LinearGradient(colors: [Color(hex: 0x3C3C3C), Color(hex: 0x2F2F2F)], startPoint: .top, endPoint: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.14)).frame(height: 1) }
        .overlay(alignment: .bottom) {
            VStack(spacing: 0) {
                Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
                Rectangle().fill(Color(hex: 0x141414)).frame(height: 1)
            }
        }
        .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
        .zIndex(1)
    }
}

/// The heavier line between columns: a dark groove with a light lip.
struct Groove: View {
    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(Color(hex: 0x111111)).frame(width: 1)
            Rectangle().fill(Color(hex: 0x1A1A1A)).frame(width: 3)
            Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1)
        }
        .frame(width: 5)
    }
}

/// The same groove, lying flat (between sections in a column).
struct FlatGroove: View {
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color(hex: 0x111111)).frame(height: 1)
            Rectangle().fill(Color(hex: 0x1A1A1A)).frame(height: 2)
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
        }
        .frame(height: 4)
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Picker("Transfers at once", selection: $model.transfersAtOnce) {
                Text("1 (one after another)").tag(1)
                Text("2").tag(2)
                Text("3").tag(3)
            }
            Text("One at a time is usually fastest: transfers that share a drive slow each other down.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Also save a CSV checksum list next to each PDF report", isOn: $model.saveCSV)
            Picker("Clip frames in the report", selection: $model.largeReportFrames) {
                Text("Compact: two columns, small frames").tag(false)
                Text("Large: three across").tag(true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(.vertical, 8)
        .onChange(of: model.transfersAtOnce) { model.pump() }
    }
}
