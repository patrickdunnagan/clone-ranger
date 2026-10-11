import AppKit
import CoreText
import CRCore

/// Everything the report needs, copied off the main thread's transfer.
struct ReportData: @unchecked Sendable {
    var source: String
    var sourceName: String
    var targets: [String]          // byte-exact paths of the new folders
    var outcome: TransferOutcome
    var started: Date

    @MainActor init(_ t: Transfer) {
        source = t.source.path
        sourceName = t.sourceName
        targets = t.targetPaths
        outcome = t.outcome!
        started = t.started ?? Date()
    }
}

enum ReportWriter {
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// "<CLIP> Reports/<CLIP> 261010-2245.pdf" inside each folder that was dropped as a destination.
    static func reportPath(target: String, date: Date, ext: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyMMdd-HHmm"
        let name = (target as NSString).lastPathComponent
        let folder = FS.join((target as NSString).deletingLastPathComponent, name + " Reports")
        var path = FS.join(folder, "\(name) \(f.string(from: date)).\(ext)")
        var i = 2
        while FS.exists(path) {
            path = FS.join(folder, "\(name) \(f.string(from: date)) \(i).\(ext)")
            i += 1
        }
        return path
    }

    /// A file URL that keeps the path's exact bytes (URL(fileURLWithPath:) can rewrite accents).
    static func exactURL(_ path: String) -> URL {
        path.withCString { p in
            CFURLCreateFromFileSystemRepresentation(nil, UnsafeRawPointer(p).assumingMemoryBound(to: UInt8.self),
                                                    strlen(p), false) as URL
        }
    }

    static func volumeName(ofTarget t: String) -> String {
        Fmt.volumeName(URL(fileURLWithPath: (t as NSString).deletingLastPathComponent))
    }

    /// Grabs the clip frames once, then writes the same report into every destination.
    static func writeAll(_ d: ReportData, csv: Bool, compactClips: Bool = true) async -> ([URL?], String?) {
        let o = d.outcome
        let clips = o.results.filter { $0.item.kind == .file && FrameGrab.isClip($0.item.path) && $0.hash != nil }
        var stills: [String: FrameGrab.Still] = [:]
        // Four at a time, from a verified copy so the card isn't read again.
        for batch in stride(from: 0, to: clips.count, by: 4).map({ Array(clips[$0..<min($0 + 4, clips.count)]) }) {
            await withTaskGroup(of: (String, FrameGrab.Still).self) { g in
                for r in batch {
                    let base = d.targets.indices.first { r.errors[$0] == nil }.map { d.targets[$0] } ?? d.source
                    g.addTask { (r.item.path, await FrameGrab.still(for: exactURL(FS.join(base, r.item.path)))) }
                }
                for await (p, s) in g { stills[p] = s }
            }
        }

        let now = Date()
        var urls: [URL?] = []
        var problem: String?
        for (i, target) in d.targets.enumerated() {
            let path = reportPath(target: target, date: now, ext: "pdf")
            do {
                try FS.makeFolders((path as NSString).deletingLastPathComponent)
                try writePDF(d, stills: stills, thisDestination: i, date: now, to: exactURL(path), compactClips: compactClips)
                if csv { try writeCSV(d, to: exactURL(String(path.dropLast(4)) + ".csv")) }
                urls.append(exactURL(path))
            } catch {
                urls.append(nil)
                problem = "Couldn't save the report next to \((target as NSString).lastPathComponent): \(error.localizedDescription)"
            }
        }
        return (urls, problem)
    }

    static func writeCSV(_ d: ReportData, to url: URL) throws {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = [(["Path", "Size (bytes)", "Modified", "xxHash64"] + d.targets.map { "Status · " + $0 }).map(q).joined(separator: ",")]
        let iso = ISO8601DateFormatter()
        for r in d.outcome.results where r.item.kind != .folder {
            let status = r.errors.indices.map { i in r.errors[i] ?? (r.retried[i] ? "Verified on second copy" : "Verified") }
            lines.append(([r.item.path, "\(r.item.size)", r.item.modified.map(iso.string) ?? "", r.hash ?? ""] + status).map(q).joined(separator: ","))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: PDF

    static func writePDF(_ d: ReportData, stills: [String: FrameGrab.Still], thisDestination: Int, date: Date, to url: URL,
                         compactClips: Bool = true) throws {
        let pdf = PDFBuilder(url: url, footer: "Clone Ranger \(appVersion) · \(d.sourceName)")
        guard let pdf else { throw CocoaError(.fileWriteUnknown) }
        let o = d.outcome
        let files = o.results.filter { $0.item.kind != .folder }
        let failed = o.results.filter { r in r.errors.contains { $0 != nil } }
        let ink = CGColor(gray: 0.1, alpha: 1), gray = CGColor(gray: 0.45, alpha: 1)
        let green = CGColor(srgbRed: 0.13, green: 0.55, blue: 0.38, alpha: 1)
        let red = CGColor(srgbRed: 0.80, green: 0.18, blue: 0.18, alpha: 1)
        let tan = CGColor(srgbRed: 0.55, green: 0.40, blue: 0.24, alpha: 1)
        let W = pdf.contentWidth, X = pdf.margin

        // Header.
        Logo.draw(in: pdf.ctx, rect: pdf.rect(x: X, y: pdf.y, w: 58, h: 45))
        pdf.text("Clone Ranger Transfer Report", x: X + 70, y: pdf.y + 4, size: 18, weight: .bold, color: ink)
        pdf.text(d.sourceName, x: X + 70, y: pdf.y + 27, size: 12, weight: .medium, color: gray)
        pdf.y += 56

        let (status, color): (String, CGColor) =
            o.fatal != nil ? ("STOPPED · \(Fmt.count(o.failedCount, "file")) not copied and verified", red)
            : o.canceled ? ("CANCELED · not everything was copied and verified", tan)
            : failed.isEmpty && o.scan.problems.isEmpty
                ? ("VERIFIED · all \(Fmt.count(o.scan.files, "file")) match the source on \(Fmt.count(d.targets.count, "destination"))"
                    + (o.recoveredCount > 0 ? " · \(o.recoveredCount) on a second copy" : ""), green)
                : ("FAILED · \(Fmt.count(o.failedCount, "file")) did not copy and verify", red)
        pdf.box(x: X, y: pdf.y, w: W, h: 26, color: color)
        pdf.text(status, x: X + 10, y: pdf.y + 7, size: 12, weight: .bold, color: CGColor(gray: 1, alpha: 1), width: W - 20)
        pdf.y += 38

        let copySecs = o.copyFinished.timeIntervalSince(o.copyStarted)
        let verifySecs = o.verifyFinished.timeIntervalSince(o.copyFinished)
        let rows: [(String, String)] = [
            ("Report created", date.formatted(date: .long, time: .shortened)),
            ("Transfer started", d.started.formatted(date: .long, time: .shortened)),
            ("Source", d.source),
            ("Files", "\(Fmt.count(o.scan.files, "file")) · \(Fmt.bytes(o.scan.bytes))"
                + (o.scan.skipped > 0 ? " · \(o.scan.skipped) Mac system files left out (.DS_Store and similar)" : "")),
            ("Copy", "\(Fmt.duration(copySecs)) · \(Fmt.rate(Double(o.scan.bytes) / max(copySecs, 0.001))) from the source"),
            ("Verify", Fmt.duration(verifySecs)),
            ("Checksum", "xxHash64, read once from the source, then every copy read back from its drive and compared"),
            ("Run by", "\(NSFullUserName()) on \(Host.current().localizedName ?? "this Mac")"),
        ]
        for (k, v) in rows {
            pdf.text(k, x: X, y: pdf.y, size: 9, weight: .semibold, color: gray)
            pdf.y += pdf.wrapped(v, x: X + 105, y: pdf.y, width: W - 105, size: 9, color: ink) + 3
        }

        pdf.y += 8
        pdf.heading("Destinations", color: ink)
        for (i, t) in d.targets.enumerated() {
            let p = i < o.destinationProblems.count ? o.destinationProblems[i] : nil
            let bad = o.results.filter { $0.errors[i] != nil }.count
            let (s, c) = p.map { ($0, red) } ?? (bad == 0 ? ("Verified", green) : (o.canceled ? "Canceled · \(bad) not done" : "\(bad) failed", bad > 0 && o.canceled ? tan : red))
            pdf.ensure(24)
            pdf.text((i == thisDestination ? "▸ " : "") + volumeName(ofTarget: t), x: X, y: pdf.y, size: 9.5, weight: .semibold, color: ink, width: 150)
            pdf.text(s, x: X + W - 150, y: pdf.y, size: 9.5, weight: .semibold, color: c, width: 150, alignRight: true)
            pdf.y += 12
            pdf.y += pdf.wrapped(t, x: X + 10, y: pdf.y, width: W - 10, size: 8, color: gray, mono: true) + 5
        }
        pdf.text("▸ is the drive this copy of the report is on.", x: X, y: pdf.y, size: 7.5, color: gray)
        pdf.y += 12

        if !o.events.isEmpty {
            pdf.y += 6
            pdf.heading("What happened along the way", color: o.events.contains(where: \.bad) ? CGColor(srgbRed: 0.85, green: 0.45, blue: 0.1, alpha: 1) : ink)
            for e in o.events {
                pdf.ensure(14)
                pdf.text(e.date.formatted(date: .omitted, time: .standard), x: X, y: pdf.y, size: 8.5, color: gray)
                pdf.y += pdf.wrapped(e.text, x: X + 70, y: pdf.y, width: W - 70, size: 8.5, color: e.bad ? CGColor(srgbRed: 0.75, green: 0.35, blue: 0.05, alpha: 1) : ink) + 3
            }
            if let f = o.fatal {
                pdf.y += pdf.wrapped("Stopped for good: \(f)", x: X, y: pdf.y, width: W, size: 9, color: red) + 4
            }
        }

        if !o.scan.problems.isEmpty || !failed.isEmpty {
            pdf.y += 6
            pdf.heading("Problems", color: red)
            for pr in o.scan.problems {
                let path = pr.path, why = pr.reason
                pdf.ensure(22)
                pdf.text(path, x: X, y: pdf.y, size: 8.5, weight: .semibold, color: ink, width: W)
                pdf.y += 11
                pdf.y += pdf.wrapped(why, x: X + 10, y: pdf.y, width: W - 10, size: 8, color: red) + 3
            }
            for r in failed.prefix(500) {
                pdf.ensure(22)
                pdf.text(r.item.path, x: X, y: pdf.y, size: 8.5, weight: .semibold, color: ink, width: W)
                pdf.y += 11
                for (i, e) in r.errors.enumerated() {
                    guard let e else { continue }
                    pdf.y += pdf.wrapped("\(volumeName(ofTarget: d.targets[i])): \(e)", x: X + 10, y: pdf.y, width: W - 10, size: 8, color: o.canceled ? tan : red) + 2
                }
                for m in r.unverified.joined() {
                    pdf.y += pdf.wrapped("Bad copy kept for checking: \(m)", x: X + 10, y: pdf.y, width: W - 10, size: 7.5, color: gray, mono: true) + 2
                }
                pdf.y += 2
            }
            if failed.count > 500 { pdf.text("…and \(failed.count - 500) more", x: X, y: pdf.y, size: 8.5, color: gray); pdf.y += 12 }
        }

        let recovered = o.results.filter { r in r.retried.contains(true) && !r.errors.contains { $0 != nil } }
        if !recovered.isEmpty {
            let amber = CGColor(srgbRed: 0.72, green: 0.50, blue: 0.0, alpha: 1)
            pdf.y += 6
            pdf.heading("Needed a second copy (\(recovered.count)) · now verified", color: amber)
            pdf.y += pdf.wrapped("These failed the first time. Clone Ranger moved the bad copy into the \"Unverified\" folder next to the copy, copied just these files again from the source and read them back; they now match and sit where they belong. The Unverified folder can be deleted once checked. Usually a network hiccup; if it happens on a local drive, check the cable, reader and drive.",
                                 x: X, y: pdf.y, width: W, size: 8, color: gray) + 6
            for r in recovered {
                pdf.ensure(22)
                pdf.text(r.item.path, x: X, y: pdf.y, size: 8.5, weight: .semibold, color: ink, width: W)
                pdf.y += 11
                for (i, e) in r.firstError.enumerated() {
                    guard let e else { continue }
                    pdf.y += pdf.wrapped("\(volumeName(ofTarget: d.targets[i])) first try: \(e)", x: X + 10, y: pdf.y, width: W - 10, size: 8, color: amber) + 2
                }
                for (i, moved) in r.unverified.enumerated() {
                    for m in moved {
                        pdf.y += pdf.wrapped("Bad copy kept for checking: \(m)", x: X + 10, y: pdf.y, width: W - 10, size: 7.5, color: gray, mono: true) + 2
                    }
                    _ = i
                }
                pdf.y += 2
            }
        }

        // Clips. Compact (default): two columns of small frames with the details beside them. Large: a grid of
        // three big frames. Either way clips over 30 s get two frames (near the start and the middle).
        let clips = files.filter { $0.item.kind == .file && FrameGrab.isClip($0.item.path) }
            .sorted { $0.item.path.localizedStandardCompare($1.item.path) == .orderedAscending }
        func drawFrame(_ img: CGImage?, x: CGFloat, y: CGFloat, w tw: CGFloat, h th: CGFloat, ext: String) {
            pdf.box(x: x, y: y, w: tw, h: th, color: CGColor(gray: 0.12, alpha: 1))
            if let img {
                let iw = CGFloat(img.width), ih = CGFloat(img.height)
                let scale = min(tw / iw, th / ih)
                pdf.image(img, x: x + (tw - iw * scale) / 2, y: y + (th - ih * scale) / 2, w: iw * scale, h: ih * scale)
            } else {
                let raw = FrameGrab.rawExtensions.contains(ext) && !FrameGrab.canPreview(ext)
                pdf.text(raw ? "RAW · no preview" : "No preview", x: x, y: y + th / 2 - 4, size: tw < 120 ? 6.5 : 8,
                         color: CGColor(gray: 0.7, alpha: 1), width: tw, center: true)
            }
        }
        func timeTag(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat, small: Bool) {
            let bw: CGFloat = small ? 48 : 62, bh: CGFloat = small ? 9 : 11
            pdf.box(x: x + 3, y: y - bh - 3, w: bw, h: bh, color: CGColor(gray: 0, alpha: 0.6))
            pdf.text(text, x: x + 3, y: y - bh - 2, size: small ? 5.5 : 6.5, color: CGColor(gray: 1, alpha: 1), width: bw, center: true)
        }
        func meta(_ r: ItemResult, _ s: FrameGrab.Still?) -> String {
            [s?.duration.map { Fmt.timecode($0) }, s?.dimensions, Fmt.bytes(r.item.size)].compactMap { $0 }.joined(separator: " · ")
        }
        if !clips.isEmpty && compactClips {
            pdf.y += 8
            pdf.heading("Clips (\(clips.count))", color: ink)
            let colGap: CGFloat = 18, cw = (W - colGap) / 2
            let tw: CGFloat = 100, th = tw * 9 / 16, pairGap: CGFloat = 4, textGap: CGFloat = 8
            func height(_ r: ItemResult) -> CGFloat { stills[r.item.path]?.middle != nil ? th + 36 : max(th, 36) }
            for i in stride(from: 0, to: clips.count, by: 2) {
                let row = Array(clips[i..<min(i + 2, clips.count)])
                let rowH = row.map(height).max() ?? th
                pdf.ensure(rowH + 4)
                for (c, r) in row.enumerated() {
                    let x = X + CGFloat(c) * (cw + colGap), y = pdf.y
                    let s = stills[r.item.path]
                    let ext = (r.item.path as NSString).pathExtension.lowercased()
                    let ok = !r.errors.contains { $0 != nil }
                    let name = (ok ? "" : "✗ ") + (r.item.path as NSString).lastPathComponent
                    drawFrame(s?.image, x: x, y: y, w: tw, h: th, ext: ext)
                    if s?.middle != nil {
                        // Two frames side by side, details underneath.
                        drawFrame(s?.middle, x: x + tw + pairGap, y: y, w: tw, h: th, ext: ext)
                        for (n, t) in (s?.times ?? []).prefix(2).enumerated() {
                            timeTag((n == 0 ? "Start " : "Middle ") + Fmt.timecode(t), x: x + CGFloat(n) * (tw + pairGap), y: y + th, w: tw, small: true)
                        }
                        pdf.text(name, x: x, y: y + th + 4, size: 8, weight: .semibold, color: ok ? ink : red, width: cw)
                        pdf.text(meta(r, s), x: x, y: y + th + 15, size: 7, color: gray, width: cw)
                        pdf.text(r.hash ?? "", x: x, y: y + th + 25, size: 6.5, color: gray, width: cw, mono: true)
                    } else {
                        // One frame, details beside it.
                        let tx = x + tw + textGap, w = cw - tw - textGap
                        pdf.text(name, x: tx, y: y + 2, size: 8, weight: .semibold, color: ok ? ink : red, width: w)
                        pdf.text(meta(r, s), x: tx, y: y + 14, size: 7, color: gray, width: w)
                        pdf.text(r.hash ?? "", x: tx, y: y + 25, size: 6.5, color: gray, width: w, mono: true)
                    }
                }
                pdf.y += rowH + 10
            }
        } else if !clips.isEmpty {
            pdf.y += 8
            pdf.heading("Clips (\(clips.count))", color: ink)
            let cols = 3, gap: CGFloat = 12
            let tw = (W - gap * CGFloat(cols - 1)) / CGFloat(cols), th = tw * 9 / 16, tile = th + 44
            var col = 0
            for r in clips {
                let s = stills[r.item.path]
                let span = s?.middle != nil ? 2 : 1
                if col + span > cols { pdf.y += tile; col = 0 }
                if col == 0 { pdf.ensure(tile) }
                let x = X + CGFloat(col) * (tw + gap)
                let w = CGFloat(span) * tw + CGFloat(span - 1) * gap
                let ext = (r.item.path as NSString).pathExtension.lowercased()
                drawFrame(s?.image, x: x, y: pdf.y, w: tw, h: th, ext: ext)
                if span == 2 {
                    drawFrame(s?.middle, x: x + tw + gap, y: pdf.y, w: tw, h: th, ext: ext)
                    for (i, t) in (s?.times ?? []).prefix(2).enumerated() {
                        timeTag((i == 0 ? "Start " : "Middle ") + Fmt.timecode(t), x: x + CGFloat(i) * (tw + gap), y: pdf.y + th, w: tw, small: false)
                    }
                }
                let ok = !r.errors.contains { $0 != nil }
                pdf.text((ok ? "" : "✗ ") + (r.item.path as NSString).lastPathComponent, x: x, y: pdf.y + th + 4, size: 8, weight: .semibold, color: ok ? ink : red, width: w)
                pdf.text(meta(r, s), x: x, y: pdf.y + th + 15, size: 7.5, color: gray, width: w)
                pdf.text(r.hash ?? "", x: x, y: pdf.y + th + 25, size: 7, color: gray, width: w, mono: true)
                col += span
                if col >= cols { pdf.y += tile; col = 0 }
            }
            if col > 0 { pdf.y += tile }
        }

        // Where everything went: per destination, each file and the folder it landed in.
        pdf.y += 8
        pdf.ensure(90)
        pdf.heading("Where everything went", color: ink)
        for (d, t) in d.targets.enumerated() {
            pdf.ensure(40)
            let problem = d < o.destinationProblems.count ? o.destinationProblems[d] : nil
            pdf.text((d == thisDestination ? "▸ " : "") + volumeName(ofTarget: t), x: X, y: pdf.y, size: 9.5, weight: .semibold, color: ink)
            pdf.y += 12
            pdf.y += pdf.wrapped(problem.map { "Not used: \($0)" } ?? t, x: X, y: pdf.y, width: W, size: 7.5, color: problem == nil ? gray : red, mono: problem == nil) + 4
            if problem != nil { continue }
            pdf.text("File", x: X, y: pdf.y, size: 7, weight: .semibold, color: gray)
            pdf.text("Folder on \(volumeName(ofTarget: t))", x: X + 170, y: pdf.y, size: 7, weight: .semibold, color: gray)
            pdf.y += 10
            for r in files.sorted(by: { $0.item.path.localizedStandardCompare($1.item.path) == .orderedAscending }) {
                pdf.ensure(10)
                let ok = r.errors[d] == nil
                let folder = (FS.join(t, r.item.path) as NSString).deletingLastPathComponent
                pdf.text((ok ? "" : "✗ ") + (r.item.path as NSString).lastPathComponent, x: X, y: pdf.y, size: 7, color: ok ? ink : red, width: 165)
                pdf.text(ok ? folder : "Not here: \(r.errors[d]!)", x: X + 170, y: pdf.y, size: 7, color: ok ? ink : red, width: W - 170, mono: ok, truncateMiddle: true)
                pdf.y += 9.5
            }
            pdf.y += 8
        }

        // Every file with its checksum.
        pdf.y += 8
        pdf.heading("All files (\(files.count))", color: ink)
        pdf.text("xxHash64", x: X, y: pdf.y, size: 7, weight: .semibold, color: gray)
        pdf.text("Size", x: X + 92, y: pdf.y, size: 7, weight: .semibold, color: gray)
        pdf.text("File", x: X + 150, y: pdf.y, size: 7, weight: .semibold, color: gray)
        pdf.y += 10
        for r in files.sorted(by: { $0.item.path.localizedStandardCompare($1.item.path) == .orderedAscending }) {
            pdf.ensure(10)
            let ok = !r.errors.contains { $0 != nil }
            pdf.text(r.item.kind == .link ? "link" : (r.hash ?? "—"), x: X, y: pdf.y, size: 7, color: ok ? ink : red, mono: true)
            pdf.text(Fmt.bytes(r.item.size), x: X + 92, y: pdf.y, size: 7, color: ink, width: 54)
            pdf.text(r.item.path + (ok && r.retried.contains(true) ? "  (second copy)" : ""), x: X + 150, y: pdf.y, size: 7, color: ok ? ink : red, width: W - 150, truncateMiddle: true)
            pdf.y += 9.5
        }
        pdf.finish()
    }
}

extension Fmt {
    /// 754.2 s → "12:34", 4000 s → "1:06:40".
    static func timecode(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Minimal top-down page layout over a PDF context (US Letter).
final class PDFBuilder {
    let ctx: CGContext
    let page = CGSize(width: 612, height: 792)
    let margin: CGFloat = 40
    var y: CGFloat = 40
    var pageNumber = 0
    let footer: String
    var contentWidth: CGFloat { page.width - margin * 2 }

    init?(url: URL, footer: String) {
        var box = CGRect(origin: .zero, size: CGSize(width: 612, height: 792))
        guard let c = CGContext(url as CFURL, mediaBox: &box, nil) else { return nil }
        ctx = c
        self.footer = footer
        newPage()
    }

    func newPage() {
        if pageNumber > 0 { drawFooter(); ctx.endPDFPage() }
        ctx.beginPDFPage(nil)
        pageNumber += 1
        y = margin
    }

    func ensure(_ h: CGFloat) { if y + h > page.height - margin - 16 { newPage() } }

    func finish() { drawFooter(); ctx.endPDFPage(); ctx.closePDF() }

    private func drawFooter() {
        let saved = y
        text("\(footer) · Page \(pageNumber)", x: margin, y: page.height - margin + 6, size: 7, color: CGColor(gray: 0.5, alpha: 1))
        y = saved
    }

    /// Top-down rect → PDF (bottom-up) rect.
    func rect(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> CGRect {
        CGRect(x: x, y: page.height - y - h, width: w, height: h)
    }

    func box(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, color: CGColor) {
        ctx.setFillColor(color)
        ctx.addPath(CGPath(roundedRect: rect(x: x, y: y, w: w, h: h), cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.fillPath()
    }

    func image(_ img: CGImage, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) {
        ctx.draw(img, in: rect(x: x, y: y, w: w, h: h))
    }

    func heading(_ s: String, color: CGColor) {
        ensure(40)
        text(s, x: margin, y: y, size: 12, weight: .bold, color: color)
        y += 18
    }

    private func attributed(_ s: String, size: CGFloat, weight: NSFont.Weight, color: CGColor, mono: Bool) -> NSAttributedString {
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        return NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor(cgColor: color) ?? .black])
    }

    /// One line, top at `y`, cut with "…" to fit `width`.
    func text(_ s: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular, color: CGColor,
              width: CGFloat? = nil, mono: Bool = false, center: Bool = false, alignRight: Bool = false, truncateMiddle: Bool = false) {
        let a = attributed(s, size: size, weight: weight, color: color, mono: mono)
        var line = CTLineCreateWithAttributedString(a)
        if let width {
            let token = CTLineCreateWithAttributedString(attributed("…", size: size, weight: weight, color: color, mono: mono))
            if let t = CTLineCreateTruncatedLine(line, Double(width), truncateMiddle ? .middle : .end, token) { line = t }
        }
        let lineW = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        var dx: CGFloat = 0
        if let width, center { dx = max(0, (width - lineW) / 2) }
        if let width, alignRight { dx = max(0, width - lineW) }
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        ctx.textPosition = CGPoint(x: x + dx, y: page.height - y - font.ascender)
        CTLineDraw(line, ctx)
    }

    /// Wrapped text; returns the height used.
    func wrapped(_ s: String, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat, color: CGColor, mono: Bool = false) -> CGFloat {
        let a = NSMutableAttributedString(attributedString: attributed(s, size: size, weight: .regular, color: color, mono: mono))
        let p = NSMutableParagraphStyle(); p.lineBreakMode = .byCharWrapping
        a.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: a.length))
        let setter = CTFramesetterCreateWithAttributedString(a)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: width, height: 10_000), nil)
        let h = ceil(fit.height)
        let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: rect(x: x, y: y, w: width, h: h + 2), transform: nil), nil)
        CTFrameDraw(frame, ctx)
        return h
    }
}
