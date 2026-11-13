import Foundation

/// Calendar arithmetic uses civil days, including daylight-saving changes.
public struct AgendaMonth {
    public let month: Date
    public let days: [Date]
    public let interval: DateInterval
    public init(containing date: Date, calendar: Calendar = .current) {
        month = calendar.dateInterval(of: .month, for: date)!.start
        let offset = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        let first = calendar.date(byAdding: .day, value: -offset, to: month)!
        days = (0..<42).map { calendar.date(byAdding: .day, value: $0, to: first)! }
        interval = DateInterval(start: first, end: calendar.date(byAdding: .day, value: 42, to: first)!)
    }
    public static func contains(start: Date, end: Date, on day: Date, calendar: Calendar = .current) -> Bool {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return false }
        // EventKit end dates are exclusive (especially for all-day events).
        if start == end { return start >= interval.start && start < interval.end }
        return start < interval.end && end > interval.start
    }
}
