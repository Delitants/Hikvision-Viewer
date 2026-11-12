import Foundation
import XCTest
@testable import CameraCore

final class AdaptiveStreamTests: XCTestCase {
    private let from = Date(timeIntervalSince1970: 1_766_000_000)
    private let to = Date(timeIntervalSince1970: 1_766_003_600)

    func testRecordedSubstreamSearchRequestsSecondaryTrack() {
        let body = RecordingSearch.request(channel: 2, start: from, end: to, quality: .sub)
        let xml = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(xml.contains("<trackID>202</trackID>"))
        XCTAssertFalse(xml.contains("<trackID>201</trackID>"))
    }

    func testRepeatedMainStallSelectsRecordedSubstreamAndRejectsItIfNoFramesArrive() throws {
        let main = try XCTUnwrap(URL(string: "rtsp://192.0.2.1/Streaming/tracks/101?starttime=20261112T000000Z&endtime=20261112T010000Z"))
        let sub = try XCTUnwrap(URL(string: "rtsp://192.0.2.1/Streaming/tracks/102?starttime=20261112T000000Z&endtime=20261112T010000Z"))
        var streams = PlaybackStreamSelection(main: main)

        let first = try XCTUnwrap(streams.retry(elapsed: 12, attempt: 1))
        XCTAssertTrue(first.path.hasSuffix("/101"))
        streams.setRecordedSubstream(sub)
        let second = try XCTUnwrap(streams.retry(elapsed: 13, attempt: 2))
        XCTAssertTrue(second.path.hasSuffix("/102"))
        XCTAssertTrue(second.absoluteString.contains("starttime=20261112T000013Z"))
        XCTAssertEqual(streams.quality, .sub)

        let third = try XCTUnwrap(streams.retry(elapsed: 13, attempt: 3))
        XCTAssertTrue(third.path.hasSuffix("/101"))
        XCTAssertEqual(streams.quality, .main)
        XCTAssertTrue(try XCTUnwrap(streams.retry(elapsed: 14, attempt: 4)).path.hasSuffix("/101"))
    }

    func testDisplayedSubstreamFramesKeepLowerBandwidthStreamForLaterRetries() throws {
        let main = try XCTUnwrap(URL(string: "rtsp://192.0.2.1/Streaming/tracks/101?starttime=20261112T000000Z&endtime=20261112T010000Z"))
        let sub = try XCTUnwrap(URL(string: "rtsp://192.0.2.1/Streaming/tracks/102?starttime=20261112T000000Z&endtime=20261112T010000Z"))
        var streams = PlaybackStreamSelection(main: main)
        streams.setRecordedSubstream(sub)
        _ = streams.retry(elapsed: 12, attempt: 2)
        streams.displayedFrame()
        let later = try XCTUnwrap(streams.retry(elapsed: 40, attempt: 1))
        XCTAssertTrue(later.path.hasSuffix("/102"))
        XCTAssertEqual(streams.quality, .sub)
    }

    func testInvalidSubstreamPlaybackAddressKeepsMainRecording() throws {
        let main = try XCTUnwrap(URL(string: "rtsp://192.0.2.1/Streaming/tracks/101?starttime=20261112T000000Z&endtime=20261112T010000Z"))
        let sub = try XCTUnwrap(URL(string: "rtsp://192.0.2.1/Streaming/tracks/102"))
        var streams = PlaybackStreamSelection(main: main)
        streams.setRecordedSubstream(sub)
        let retry = try XCTUnwrap(streams.retry(elapsed: 10, attempt: 2))
        XCTAssertTrue(retry.path.hasSuffix("/101"))
        XCTAssertEqual(streams.quality, .main)
    }
}
