import AppKit

/// Test hook: CR_AUTOPLAY="<source>|<dest>|<dest>…" fills in a transfer, runs it, and saves window
/// pictures to CR_SNAP_DIR along the way, then quits. Environment variables, not arguments: AppKit
/// treats file paths on the command line as documents to open.
@MainActor
enum Autoplay {
    static func startIfAsked(model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        guard let spec = env["CR_AUTOPLAY"] else { return }
        let dir = URL(fileURLWithPath: env["CR_SNAP_DIR"] ?? NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let parts = spec.split(separator: "|").map { URL(fileURLWithPath: String($0)) }
        let extra = env["CR_AUTOPLAY_QUEUE"].map { URL(fileURLWithPath: $0) }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            snap(dir, "1 empty")
            model.setSource(parts[0])
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
            while model.busy || !model.queued.isEmpty {
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
                if t?.state == .verifying, !sawVerify, (t?.fraction ?? 0) > 0.3 { sawVerify = true; snap(dir, "4 verifying") }
            }
            try? await Task.sleep(for: .seconds(1))
            model.selected = model.history.first?.id
            try? await Task.sleep(for: .seconds(0.5))
            snap(dir, "5 done")
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
