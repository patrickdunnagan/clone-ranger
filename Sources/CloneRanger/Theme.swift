import SwiftUI

/// Sync Folder Checker's palette, a touch lighter.
enum T {
    static let bg = Color(hex: 0x262626)
    static let side = Color(hex: 0x2B2B2B)
    static let panel = Color(hex: 0x313131)
    static let bar = Color(hex: 0x2E2E2E)
    static let fill = Color.white.opacity(0.08)
    static let fill2 = Color.white.opacity(0.045)
    static let sep = Color.white.opacity(0.09)
    static let sepStrong = Color.white.opacity(0.16)
    static let label = Color.white.opacity(0.88)
    static let label2 = Color.white.opacity(0.58)
    static let label3 = Color.white.opacity(0.36)
    static let blue = Color(hex: 0x2E8CE6)
    static let purple = Color(hex: 0x9B7FE6)
    static let green = Color(hex: 0x4FB08F)
    static let red = Color(hex: 0xEF5B5B)
    static let orange = Color(hex: 0xF08A3C)
    static let tan = Color(hex: 0xB08A62)
    static let amber = Color(hex: 0xE5B53C)
    static let radius: CGFloat = 7
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var large = false
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, large: large)
    }
    private struct Styled: View {
        let configuration: Configuration
        let large: Bool
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(.system(size: large ? 14 : 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, large ? 18 : 12)
                .padding(.vertical, large ? 9 : 6)
                .background(RoundedRectangle(cornerRadius: T.radius)
                    .fill(T.blue.opacity(configuration.isPressed ? 0.8 : 1)))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
        }
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color = T.label
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, tint: tint)
    }
    private struct Styled: View {
        let configuration: Configuration
        let tint: Color
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: T.radius)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.14 : 0.08)))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
        }
    }
}

/// Small uppercase section heading.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(T.label3)
    }
}

/// Rounded pill with a solid color.
struct Pill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(color))
    }
}

/// Thin progress bar.
struct Bar: View {
    var fraction: Double
    var color: Color
    var height: CGFloat = 8
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2).fill(T.fill)
                RoundedRectangle(cornerRadius: height / 2).fill(color)
                    .frame(width: max(fraction > 0 ? height : 0, g.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(T.panel))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(T.sep, lineWidth: 1))
    }
}

enum Fmt {
    static func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: n)
    }

    /// "95.1 of 148.6 GB", or "820 MB of 1.2 GB" when the units differ.
    static func partOf(_ part: Int64, _ whole: Int64) -> String {
        let a = bytes(part), b = bytes(whole)
        let ua = a.split(separator: " ").last, ub = b.split(separator: " ").last
        return ua == ub ? "\(a.split(separator: " ").first!) of \(b)" : "\(a) of \(b)"
    }

    static func rate(_ bps: Double) -> String {
        bps >= 1e9 ? String(format: "%.2f GB/s", bps / 1e9) : String(format: "%.0f MB/s", bps / 1e6)
    }

    static func duration(_ s: Double) -> String {
        let t = Int(s.rounded())
        if t < 60 { return "\(max(t, 0)) sec" }
        if t < 3600 { return "\(t / 60) min \(t % 60) sec" }
        return "\(t / 3600) hr \((t / 60) % 60) min"
    }

    static func count(_ n: Int, _ noun: String) -> String {
        "\(n.formatted()) \(noun)\(n == 1 ? "" : "s")"
    }

    static func time(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? "Today " + d.formatted(date: .omitted, time: .shortened)
            : d.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    static func shortPath(_ url: URL?) -> String {
        guard let url else { return "" }
        return url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    /// "Horizon › Projects": the drive or server, then the folders down to here (the last few if it's deep).
    static func place(_ url: URL, includeVolume: Bool = true) -> String {
        let vol = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume?.standardizedFileURL.path ?? "/"
        let path = url.standardizedFileURL.path
        var rel = path.hasPrefix(vol) ? String(path.dropFirst(vol.count)) : path
        if vol == "/" && rel.hasPrefix(String(NSHomeDirectory().dropFirst())) {
            rel = "~" + rel.dropFirst(NSHomeDirectory().count - 1)
        }
        var parts = rel.split(separator: "/").map(String.init)
        if parts.count > 4 { parts = ["…"] + parts.suffix(3) }
        if includeVolume { parts.insert(volumeName(url), at: 0) }
        return parts.isEmpty ? "" : (includeVolume ? "" : "› ") + parts.joined(separator: " › ")
    }

    /// "HVP SSD 07", or "Macintosh HD" for the Mac's own drive.
    static func volumeName(_ url: URL) -> String {
        (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName ?? "Macintosh HD"
    }
}
