import Foundation

/// Extracts action items from a composed meeting summary (the markdown
/// `MeetingSummary.compose` prepends to transcripts) and persists them to
/// the `action_items` table so the hub can aggregate and check them off.
enum ActionItems {

    /// Bullets under the `### Action items` heading. Tolerates `-`, `*`, and
    /// numbered bullets; a lone "none" bullet, a missing heading, or
    /// malformed markdown all yield an empty list — never an error.
    static func parse(_ content: String) -> [String] {
        var items: [String] = []
        var inSection = false
        for raw in content.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                inSection = line.lowercased().hasSuffix("action items")
                continue
            }
            if line == "---" { inSection = false; continue }
            guard inSection, !line.isEmpty else { continue }

            var text: String?
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                text = String(line.dropFirst(2))
            } else if let r = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                text = String(line[r.upperBound...])
            }
            guard var t = text?.trimmingCharacters(in: .whitespaces), !t.isEmpty
            else { continue }
            t = t.replacingOccurrences(of: "**", with: "")
            let normalized = t.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if normalized == "none" { continue }
            items.append(t)
        }
        return items
    }

    /// Parse `content` and persist the items for one meeting. Idempotent
    /// (delete + re-insert). Failures are logged, never thrown — extraction
    /// must not break the save path.
    static func extract(store: Store, snapshotId: Int64, content: String) {
        do {
            try store.replaceActionItems(snapshotId: snapshotId, texts: parse(content))
        } catch {
            fputs("smriti action-items: extract failed for #\(snapshotId): \(error)\n", stderr)
        }
    }

    /// One-time pass over meetings recorded before extraction existed. Only
    /// touches meetings with no extracted rows, so checked-off state on
    /// already-extracted meetings survives.
    static func backfill(store: Store) {
        guard let ids = try? store.meetingIdsWithoutActionItems(), !ids.isEmpty else { return }
        for id in ids {
            guard let snap = try? store.getSnapshot(id: id) else {
                fputs("smriti action-items: backfill skipped #\(id) (unreadable)\n", stderr)
                continue
            }
            extract(store: store, snapshotId: id, content: snap.content)
        }
        fputs("smriti action-items: backfill scanned \(ids.count) meeting(s)\n", stderr)
    }
}
