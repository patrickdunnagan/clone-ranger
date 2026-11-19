import Foundation

/// Works out a card's reel name ("A301", "B002") from how the camera named things, so a transfer can be
/// named after it without anyone typing. Only looks at names already found by the scan: nothing extra is read.
///
/// What cameras do (camera letter + reel number at the start of every clip):
/// - ARRI, Canon Cinema, Sony FX6/FX9/Venice (camera ID naming): A301C004_240101AB.MXF
/// - ARRI ALEXA 35 and newer: A_0001C004_...
/// - RED: a folder per reel and per clip: A001_0101XY.RDM / A001_C004_0101XY.RDC / A001_C004_0101XY_001.R3D
/// - Blackmagic: A001_08201230_C004.braw
/// Cameras that number clips without a reel (Sony FX3 "C0001.MP4", GoPro, phones) give nothing; the card's
/// own name is used instead.
public enum Reel {
    public struct Found: Equatable, Sendable {
        public var name: String       // "A301", or "A301–A303" when a card holds several reels
        public var why: String        // "from the clip names" / "from the RED reel folder"
    }

    static let clipExtensions: Set<String> = ["mov", "mp4", "mxf", "braw", "r3d", "ari", "arx", "crm", "mts", "avi", "mkv", "m4v"]

    // A301C004…  /  A301_C004…  /  A301_08201230_C004…  /  A_0001C004…
    nonisolated(unsafe) private static let clipPattern = try! NSRegularExpression(
        pattern: #"^([A-Z]_[0-9]{4}|[A-Z][0-9]{3})(?=C[0-9]{3}|_C[0-9]{3}|_[0-9]{6,})"#)
    // A001_0101XY.RDM (the reel folder RED makes on every card)
    nonisolated(unsafe) private static let rdmPattern = try! NSRegularExpression(pattern: #"^([A-Z][0-9]{3})_[0-9A-Z]+\.RDM$"#,
                                                                                options: [.caseInsensitive])

    /// `paths` are the scanned items' paths (relative to what was dropped), `isFolder` says which are folders.
    public static func detect(paths: [(path: String, isFolder: Bool)]) -> Found? {
        // RED's reel folder is the clearest sign there is.
        var rdm: [String] = []
        for p in paths {
            for part in p.path.split(separator: "/") where part.uppercased().hasSuffix(".RDM") {
                if let r = first(rdmPattern, String(part)) { rdm.append(r.uppercased()) }
            }
        }
        if let r = summarize(rdm) { return Found(name: r, why: "from the RED reel folder") }

        var reels: [String] = []
        for p in paths where !p.isFolder {
            let file = (p.path as NSString).lastPathComponent
            guard clipExtensions.contains((file as NSString).pathExtension.lowercased()) else { continue }
            if let r = first(clipPattern, file) { reels.append(r) }
        }
        return summarize(reels).map { Found(name: $0, why: "from the clip names") }
    }

    public static func detect(_ scan: ScanResult) -> Found? {
        detect(paths: scan.items.map { ($0.path, $0.kind == .folder) })
    }

    private static func first(_ re: NSRegularExpression, _ s: String) -> String? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// One reel → "A301". Several → "A301–A303" (first to last). None → nil.
    private static func summarize(_ found: [String]) -> String? {
        let distinct = Set(found).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard let a = distinct.first, let z = distinct.last else { return nil }
        return a == z ? a : "\(a)–\(z)"
    }
}
