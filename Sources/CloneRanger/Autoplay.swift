import AppKit
import CRCore

/// Test hook: CR_AUTOPLAY="<source>|<dest>|<dest>…" fills in a transfer, runs it, and saves window
/// pictures to CR_SNAP_DIR along the way, then quits. Environment variables, not arguments: AppKit
/// treats file paths on the command line as documents to open.
@MainActor
enum Autoplay {
    static func startIfAsked(model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        // CR_PREFILL="<source>|<dest>…": fill in a transfer but leave starting it to the person.
        if let spec = env["CR_PREFILL"] {
            let parts = spec.split(separator: "|").map { URL(fileURLWithPath: String($0)) }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                model.setSource(parts[0])
                for d in parts.dropFirst() { model.addDestination(d) }
            }
            return
        }
        if env["CR_AUTOPLAY"] == nil, let mode = env["CR_AUTOPLAY_REOPEN"] {
            // Test: opened after a crash; show what's offered, resume, wait for the end.
            let dir = URL(fileURLWithPath: env["CR_SNAP_DIR"] ?? NSTemporaryDirectory())
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                snap(dir, "9 reopened")
                guard let t = model.interrupted.first else { snap(dir, "9b nothing to resume"); NSApp.terminate(nil); return }
                while t.waitingFor != nil { try? await Task.sleep(for: .seconds(0.5)) }
                model.resume(t, mode == "quick" ? .quick : .full)
                while model.busy { try? await Task.sleep(for: .seconds(0.5)) }
                try? await Task.sleep(for: .seconds(1))
                model.selected = t.id
                try? await Task.sleep(for: .seconds(0.5))
                snap(dir, "10 done after reopen")
                NSApp.terminate(nil)
            }
            return
        }
        guard let spec = env["CR_AUTOPLAY"] else { return }
        let dir = URL(fileURLWithPath: env["CR_SNAP_DIR"] ?? NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let parts = spec.split(separator: "|").map { URL(fileURLWithPath: String($0)) }
        let extra = env["CR_AUTOPLAY_QUEUE"].map { URL(fileURLWithPath: $0) }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            // Test: CR_WINDOW_WIDTH=<points> to check the layout when the window is narrow.
            if let w = env["CR_WINDOW_WIDTH"].flatMap(Double.init), let win = NSApp.windows.first(where: { $0.isVisible }) {
                var f = win.frame
                f.size.width = w
                win.setFrame(f, display: true)
                try? await Task.sleep(for: .seconds(0.5))
            }
            snap(dir, "1 empty")
            if let items = env["CR_AUTOPLAY_ITEMS"] {
                model.setSources(items.split(separator: "|").map { parts[0].appendingPathComponent(String($0)) })
            } else {
                model.setSource(parts[0])
            }
            for d in parts.dropFirst() { model.addDestination(d) }
            while model.draftScan == nil { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .seconds(0.5))
            snap(dir, "2 ready")
            model.commit()
            if let extra {
                // A second transfer waiting in the queue.
                try? await Task.sleep(for: .seconds(1))
                model.selected = nil
                model.setSource(extra)
                for d in parts.dropFirst() { model.addDestination(d) }
                while model.draftScan == nil { try? await Task.sleep(for: .milliseconds(100)) }
                model.commit()
                model.selected = model.transfers.first?.id
            }
            var shots = 0
            var sawVerify = false
            let resumeMode = env["CR_AUTOPLAY_RESUME"].map { $0 == "quick" ? ResumeMode.quick : .full }
            var sawStop = false, sawBack = false, sawRecheck = false
            // Test: CR_TEST_EJECT=<volume>: Eject must be refused while a transfer uses it, and work once it's done.
            let ejectVol = env["CR_TEST_EJECT"].map { URL(fileURLWithPath: $0) }
            var ejectLog = "", triedEarly = false
            while model.busy || !model.queued.isEmpty || (resumeMode != nil && !model.interrupted.isEmpty) {
                if let mode = resumeMode, let s = model.interrupted.first {
                    if s.waitingFor != nil && !sawStop { sawStop = true; snap(dir, "6 unplugged") }
                    if s.waitingFor == nil {
                        if !sawBack { sawBack = true; try? await Task.sleep(for: .seconds(0.5)); snap(dir, "7 ready to resume") }
                        model.resume(s, mode)
                    }
                }
                if model.active.first?.state == .rechecking, !sawRecheck { sawRecheck = true; try? await Task.sleep(for: .seconds(0.4)); snap(dir, "8 rechecking") }
                try? await Task.sleep(for: .seconds(1))
                let t = model.active.first
                if t?.state == .copying, shots < 1, (t?.fraction ?? 0) > 0.3 {
                    shots += 1
                    snap(dir, "3 copying")
                    if env["CR_TEST_PAUSE"] != nil, let t {
                        model.togglePause(t)
                        try? await Task.sleep(for: .seconds(2))
                        snap(dir, "3b paused")
                        model.togglePause(t)
                    }
                }
                if env["CR_TEST_CANCEL"] != nil, let t, t.state == .verifying, (t.fraction) > 0.2, !t.control.cancelled {
                    t.control.cancelled = true   // the button asks first; the test skips the question
                }
                if let v = ejectVol, !triedEarly, let t {
                    triedEarly = true
                    ejectLog += "during \(t.state): using=\(model.transferUsing(volume: v)?.displayName ?? "nil")\n"
                    model.eject(v, name: v.lastPathComponent)
                    try? await Task.sleep(for: .seconds(2))
                    ejectLog += "after refused eject: mounted=\(FileManager.default.fileExists(atPath: v.path)) notice=\(model.notice ?? "nil")\n"
                }
                if t?.state == .verifying, !sawVerify, (t?.fraction ?? 0) > 0.3 { sawVerify = true; snap(dir, "4 verifying") }
            }
            try? await Task.sleep(for: .seconds(1))
            model.selected = model.history.first?.id
            try? await Task.sleep(for: .seconds(0.5))
            snap(dir, "5 done")
            if let v = ejectVol {
                ejectLog += "after done: using=\(model.transferUsing(volume: v)?.displayName ?? "nil")\n"
                model.eject(v, name: v.lastPathComponent)
                try? await Task.sleep(for: .seconds(4))
                ejectLog += "after eject: mounted=\(FileManager.default.fileExists(atPath: v.path))\n"
                try? ejectLog.write(to: dir.appendingPathComponent("eject.txt"), atomically: true, encoding: .utf8)
            }
            if env["CR_STAY"] == nil { NSApp.terminate(nil) }
        }
    }

    static func snap(_ dir: URL, _ name: String) {
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }), let v = w.contentView,
              let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
    }
}
