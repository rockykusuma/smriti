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
}
