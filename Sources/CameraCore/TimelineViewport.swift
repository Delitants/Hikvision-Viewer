import Foundation

public struct TimelineViewport {
    public let start: Date
    public let end: Date
    public let center: Date
    public let span: TimeInterval

    public init(start: Date, end: Date, center: Date, span: TimeInterval) {
        self.start = start
        self.end = end
        self.center = min(max(center, start), end.addingTimeInterval(-1))
        self.span = max(300, min(7 * 86400, span))
    }

    public func time(at fraction: Double) -> Date {
        min(max(center.addingTimeInterval((fraction - 0.5) * span), start), end.addingTimeInterval(-1))
    }

    public func fraction(for date: Date) -> Double { 0.5 + date.timeIntervalSince(center) / span }

    public func tickInterval(width: Double) -> TimeInterval {
        let minimum = span / max(2, width / 90)
        return [1, 5, 10, 30, 60, 300, 600, 900, 1800, 3600, 7200, 21600, 43200, 86400]
            .first(where: { Double($0) >= minimum }).map(Double.init) ?? 86400
    }
}
