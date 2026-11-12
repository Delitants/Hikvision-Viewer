import Foundation
import XCTest
@testable import CameraCore

final class TimelineViewportTests: XCTestCase {
    func testCenteredPlayheadAndClickMappingClampToSelectedDates() {
        let start = Date(timeIntervalSince1970: 0)
        let end = start.addingTimeInterval(2 * 86400)
        let center = start.addingTimeInterval(86400)
        let view = TimelineViewport(start: start, end: end, center: center, span: 86400)
        XCTAssertEqual(view.fraction(for: center), 0.5)
        XCTAssertEqual(view.time(at: 0.25), center.addingTimeInterval(-21600))
        XCTAssertEqual(view.time(at: -10), start)
        XCTAssertEqual(view.time(at: 10), end.addingTimeInterval(-1))
    }

    func testZoomLimitsAndTickDensityRemainUsableAtSmallWidths() {
        let start = Date(timeIntervalSince1970: 0), end = Date(timeIntervalSince1970: 86400)
        let close = TimelineViewport(start: start, end: end, center: start, span: 1)
        let wide = TimelineViewport(start: start, end: end, center: end, span: 1_000_000)
        XCTAssertEqual(close.span, 300)
        XCTAssertEqual(wide.span, 7 * 86400)
        XCTAssertEqual(wide.center, end.addingTimeInterval(-1))
        XCTAssertGreaterThanOrEqual(wide.tickInterval(width: 600), wide.tickInterval(width: 1400))
    }

    func testRecorderMetadataKeepsEventTypeForTimelineBand() throws {
        let xml = """
        <CMSearchResult><searchMatchItem><timeSpan><startTime>2026-01-01T00:00:00Z</startTime><endTime>2026-01-01T00:01:00Z</endTime></timeSpan><mediaSegmentDescriptor><playbackURI>rtsp://192.0.2.1/recording</playbackURI></mediaSegmentDescriptor><metadataDescriptor>//recordType.meta.std-cgi.com/motion</metadataDescriptor></searchMatchItem></CMSearchResult>
        """
        XCTAssertEqual(try RecordingSearch.parse(Data(xml.utf8)).first?.kind, .event)
    }
}
