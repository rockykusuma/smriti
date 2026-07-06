import Foundation

/// A group of snapshots that share the same hour.
struct HourGroup {
    /// Formatted hour label, e.g. "9:00 AM".
    let hour: String
    /// Snapshots in this hour, oldest first.
    let snapshots: [Store.Snapshot]
}

/// Utilities for organizing snapshots into timeline views.
enum TimelineHelpers {

    /// Group snapshots by the hour of their `lastSeenAt` timestamp.
    /// Returns groups in chronological order (oldest hour first),
    /// with snapshots within each group sorted oldest first.
    static func groupByHour(_ snapshots: [Store.Snapshot]) -> [HourGroup] {
        guard !snapshots.isEmpty else { return [] }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        fmt.locale = Locale(identifier: "en_US_POSIX")

        let hourFmt = DateFormatter()
        hourFmt.dateFormat = "h:mm a"
        hourFmt.locale = Locale(identifier: "en_US_POSIX")

        let sorted = snapshots.sorted { $0.lastSeenAt < $1.lastSeenAt }

        var buckets: [String: [Store.Snapshot]] = [:]
        for s in sorted {
            guard fmt.date(from: s.lastSeenAt) != nil else { continue }
            let hourKey = String(s.lastSeenAt.prefix(13)) // "yyyy-MM-dd HH"
            buckets[hourKey, default: []].append(s)
        }

        return buckets.keys.sorted().compactMap { key in
            guard let groupSnaps = buckets[key],
                  let firstDate = fmt.date(from: groupSnaps[0].lastSeenAt)
            else { return nil }
            return HourGroup(
                hour: hourFmt.string(from: firstDate),
                snapshots: groupSnaps)
        }
    }
}
