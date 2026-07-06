import XCTest
@testable import SmritiKit

final class TimelineHelpersTests: XCTestCase {

    private let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private let hourFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func snap(id: Int64, hour: Int, minute: Int = 0, app: String = "Test") -> Store.Snapshot {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        let date = cal.date(from: comps)!
        let ts = fmt.string(from: date)
        return Store.Snapshot(
            id: id, app: app, bundleId: "com.\(app.lowercased())",
            windowTitle: "Window \(id)", content: "content \(id)", url: "",
            capturedAt: ts, lastSeenAt: ts)
    }

    func testGroupByHourEmpty() {
        let groups = TimelineHelpers.groupByHour([])
        XCTAssertTrue(groups.isEmpty)
    }

    func testGroupByHourSingleGroup() {
        let s1 = snap(id: 1, hour: 9, minute: 14)
        let s2 = snap(id: 2, hour: 9, minute: 45)
        let groups = TimelineHelpers.groupByHour([s1, s2])
        XCTAssertEqual(groups.count, 1, "snapshots in the same hour should group together")
        XCTAssertEqual(groups[0].snapshots.count, 2)
    }

    func testGroupByHourPreservesChronologicalOrder() {
        let s1 = snap(id: 1, hour: 9, minute: 30)
        let s2 = snap(id: 2, hour: 9, minute: 15)
        let s3 = snap(id: 3, hour: 9, minute: 45)

        let groups = TimelineHelpers.groupByHour([s3, s1, s2])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].snapshots.map(\.id), [2, 1, 3],
            "snapshots within a group should be chronological")
    }

    func testGroupByHourSeparatesDifferentHours() {
        let s1 = snap(id: 1, hour: 9)
        let s2 = snap(id: 2, hour: 14)

        let groups = TimelineHelpers.groupByHour([s1, s2])
        XCTAssertEqual(groups.count, 2, "snapshots in different hours should be in separate groups")
    }

    func testGroupByHourFormatsTimeCorrectly() {
        let s = snap(id: 1, hour: 14, minute: 30)
        let groups = TimelineHelpers.groupByHour([s])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].hour, "2:30 PM")
    }

    func testGroupByHourMultipleDays() {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        fmt.locale = Locale(identifier: "en_US_POSIX")

        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 10; comps.minute = 0; comps.second = 0
        let today = cal.date(from: comps)!
        comps.day = (comps.day ?? 1) - 1
        let yesterday = cal.date(from: comps)!

        let s1 = Store.Snapshot(
            id: 1, app: "A", bundleId: "com.a", windowTitle: "Y",
            content: "yesterday", url: "",
            capturedAt: fmt.string(from: yesterday),
            lastSeenAt: fmt.string(from: yesterday))
        let s2 = Store.Snapshot(
            id: 2, app: "B", bundleId: "com.b", windowTitle: "T",
            content: "today", url: "",
            capturedAt: fmt.string(from: today),
            lastSeenAt: fmt.string(from: today))

        let groups = TimelineHelpers.groupByHour([s2, s1])
        XCTAssertEqual(groups.count, 2)
        // Yesterday's group should come first
        XCTAssertEqual(groups[0].snapshots[0].id, 1)
        XCTAssertEqual(groups[1].snapshots[0].id, 2)
    }
}
