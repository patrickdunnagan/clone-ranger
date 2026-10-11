import SwiftUI

/// Active, queued, then finished transfers (newest first). Cleared when the app quits.
struct RightColumn: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                section("Active", model.active)
                section("Stopped", model.interrupted)
                section("Queued", model.queued)
                section("History", model.history)
                if model.transfers.isEmpty {
                    Text("Transfers show up here. History clears when Clone Ranger quits; the PDF reports stay with the copies.")
                        .font(.system(size: 12))
                        .foregroundStyle(T.label3)
                        .padding(.horizontal, 14)
                        .padding(.top, 14)
                }
            }
            .padding(.vertical, 10)
        }
        .background(T.side)
    }

    @ViewBuilder private func section(_ title: String, _ items: [Transfer]) -> some View {
        if !items.isEmpty {
            SectionLabel(text: title)
                .padding(.horizontal, 14)
                .padding(.top, 8)
            ForEach(items) { t in
                TransferRow(t: t, selected: model.selected == t.id)
                    .onTapGesture { model.selected = t.id }
            }
        }
    }
}

struct TransferRow: View {
    @ObservedObject var t: Transfer
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(t.displayName)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(T.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Pill(text: t.label, color: t.color)
            }
            Text(meta)
                .font(.system(size: 11.5))
                .foregroundStyle(T.label2)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(alignment: .leading) {
            GeometryReader { g in
                Rectangle()
                    .fill(t.color.opacity(t.state == .queued ? 0 : 0.2))
                    .frame(width: g.size.width * fill)
                    .animation(.linear(duration: 0.25), value: fill)
            }
        }
        .background(T.panel)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? T.blue : T.sep, lineWidth: selected ? 2 : 1))
        .opacity(t.state == .queued ? 0.8 : 1)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
    }

    private var fill: Double { t.state.finished ? 1 : t.fraction }

    private var meta: String {
        let drives = "→ \(Fmt.count(t.parents.count, "drive"))"
        switch t.state {
        case .queued:
            return [Fmt.bytes(t.totalBytes), drives].joined(separator: " · ")
        case .scanning, .copying, .verifying:
            var parts = ["\(Int((t.fraction * 100).rounded(.down)))%"]
            if t.state == .verifying { parts[0] += " checked" }
            if t.speed > 0 { parts.append(Fmt.rate(t.speed)) }
            parts.append(drives)
            if let s = t.secondsLeft { parts.append("~" + Fmt.duration(s)) }
            return parts.joined(separator: " · ")
        case .interrupted:
            return t.waitingFor.map { "Waiting for \($0) · " + Fmt.bytes(t.outcome?.copiedBytes ?? 0) + " copied" } ?? "Ready to resume · choose how"
        case .rechecking:
            return "\(Int((t.fraction * 100).rounded(.down)))% re-checked · " + drives
        case .retrying:
            return "Copying \(Fmt.count(t.retryCount, "failed file")) again · " + drives
        case .report:
            return "Writing report · " + drives
        default:
            let again = t.outcome?.recoveredCount ?? 0
            return ([Fmt.time(t.finished ?? t.created), Fmt.bytes(t.totalBytes), drives, Fmt.duration(t.elapsed)]
                    + (again > 0 ? ["\(again) re-copied"] : [])).joined(separator: " · ")
        }
    }
}
