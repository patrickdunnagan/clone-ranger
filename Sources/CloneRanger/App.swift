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
            for t in m.active where t.state != .report { Journal.saveNow(t) }
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
                .frame(minWidth: 1100, minHeight: 680)
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
            HStack(spacing: 0) {
                Sidebar().frame(width: 260)
                Divider().overlay(T.sep)
                CenterColumn().frame(minWidth: 520)
                Divider().overlay(T.sep)
                RightColumn().frame(width: 370)
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
        .frame(height: 46)
        .frame(maxWidth: .infinity)
        .background(T.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(T.sepStrong).frame(height: 1) }
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
