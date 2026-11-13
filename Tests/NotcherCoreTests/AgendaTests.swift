import XCTest
@testable import NotcherCore

final class AgendaTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Paris")!
        value.firstWeekday = 2
        return value
    }
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
    func testMonthGridCrossesYearsAndKeepsFirstWeekday() {
        let grid = AgendaMonth(containing: date(2027, 1, 15), calendar: calendar)
        XCTAssertEqual(grid.days.count, 42)
        XCTAssertEqual(grid.days.first, date(2026, 12, 28))
        XCTAssertEqual(calendar.component(.weekday, from: grid.days[0]), 2)
        XCTAssertEqual(grid.interval.end, date(2027, 2, 8))
    }
    func testLeapFebruaryIncludes29AndGridCoversWholeMonth() {
        let grid = AgendaMonth(containing: date(2028, 2, 10), calendar: calendar)
        XCTAssertTrue(grid.days.contains(date(2028, 2, 29)))
        XCTAssertEqual(grid.days.filter { calendar.component(.month, from: $0) == 2 }.count, 29)
    }
    func testDSTMonthUsesLocalMidnightsWithoutSkippingDays() {
        let grid = AgendaMonth(containing: date(2026, 3, 29), calendar: calendar)
        XCTAssertTrue(grid.days.allSatisfy { calendar.component(.hour, from: $0) == 0 })
        let springDay = date(2026, 3, 29), next = date(2026, 3, 30)
        XCTAssertEqual(next.timeIntervalSince(springDay), 23 * 3600)
        XCTAssertTrue(AgendaMonth.contains(start: springDay, end: next, on: springDay, calendar: calendar))
        XCTAssertFalse(AgendaMonth.contains(start: springDay, end: next, on: next, calendar: calendar))
    }
    func testOvernightEventAppearsOnBothDaysButNotAtExclusiveEnd() {
        let start = date(2026, 11, 13, 23), end = date(2026, 11, 14, 2)
        XCTAssertTrue(AgendaMonth.contains(start: start, end: end, on: date(2026, 11, 13), calendar: calendar))
        XCTAssertTrue(AgendaMonth.contains(start: start, end: end, on: date(2026, 11, 14), calendar: calendar))
        XCTAssertFalse(AgendaMonth.contains(start: start, end: end, on: date(2026, 11, 15), calendar: calendar))
        XCTAssertFalse(AgendaMonth.contains(start: start, end: date(2026, 11, 14), on: date(2026, 11, 14), calendar: calendar))
    }
}
