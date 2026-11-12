import Foundation
import XCTest
@testable import CameraCore

final class PlaybackRecoveryTests: XCTestCase {
    func testDisplayedFramesAdvanceTimelineWhenRecorderOmitsPlaybackClock() {
        var recovery = PlaybackRecovery(now: 0, duration: 120)
        _ = recovery.observe(now: 5, mediaTime: 0, pictures: 1, state: .playing)
        _ = recovery.observe(now: 6, mediaTime: 0, pictures: 10, state: .playing)
        let moving = recovery.observe(now: 7, mediaTime: 0, pictures: 20, state: .playing)
        XCTAssertEqual(moving.progress, 2)
        _ = recovery.observe(now: 16, mediaTime: 0, pictures: 20, state: .playing)
        XCTAssertEqual(recovery.confirmedElapsed, 2)
    }

    func testStallResumesFromDisplayedFrameInsteadOfAdvancingClock() {
        var recovery = PlaybackRecovery(now: 0, duration: 120)
        _ = recovery.observe(now: 2, mediaTime: 2, pictures: 20, state: .playing)
        _ = recovery.observe(now: 4, mediaTime: 4, pictures: 40, state: .playing)
        let update = recovery.observe(now: 17, mediaTime: 17, pictures: 40, state: .playing)
        guard case let .retry(elapsed, _, _) = update.action else { return XCTFail("Frozen video must reconnect") }
        XCTAssertEqual(elapsed, 3)
        XCTAssertEqual(recovery.confirmedElapsed, 4)
    }

    func testSlowFramesKeepConnectionAndLongStartupGetsTimeToBuffer() {
        var recovery = PlaybackRecovery(now: 0, duration: 120)
        XCTAssertEqual(recovery.observe(now: 25, mediaTime: 0, pictures: 0, state: .buffering).action, .none)
        for second in stride(from: 26, through: 80, by: 4) {
            XCTAssertEqual(recovery.observe(now: Double(second), mediaTime: Double(second-25)/4,
                                            pictures: second, state: .playing).action, .none)
        }
    }

    func testRepeatedFailuresBackOffAndResumeNotificationRequiresFrames() {
        var recovery = PlaybackRecovery(now: 0, duration: 120)
        XCTAssertEqual(recovery.observe(now: 1, mediaTime: 0, pictures: 0, state: .failed).action,
                       .retry(elapsed: 0, attempt: 1, cacheMilliseconds: 5000))
        XCTAssertEqual(recovery.observe(now: 2, mediaTime: 0, pictures: 0, state: .failed).action, .none)
        XCTAssertEqual(recovery.observe(now: 3, mediaTime: 0, pictures: 0, state: .failed).action,
                       .retry(elapsed: 0, attempt: 2, cacheMilliseconds: 7000))
        XCTAssertFalse(recovery.observe(now: 4, mediaTime: 10, pictures: 0, state: .playing).resumed)
        XCTAssertTrue(recovery.observe(now: 5, mediaTime: 1, pictures: 10, state: .playing).resumed)
    }

    func testPauseDoesNotTriggerRecoveryAndNaturalEndCompletesOnce() {
        var recovery = PlaybackRecovery(now: 0, duration: 20)
        _ = recovery.observe(now: 2, mediaTime: 2, pictures: 20, state: .playing)
        XCTAssertEqual(recovery.observe(now: 90, mediaTime: 2, pictures: 20, state: .paused).action, .none)
        XCTAssertEqual(recovery.observe(now: 100, mediaTime: 2, pictures: 20, state: .playing).action, .none)
        XCTAssertEqual(recovery.observe(now: 116, mediaTime: 19, pictures: 190, state: .ended).action, .finished)
        XCTAssertEqual(recovery.observe(now: 120, mediaTime: 19, pictures: 190, state: .ended).action, .none)
    }

    func testEarlyEndRetriesAndLastFrameAtBoundaryCompletesEvenWithoutEndedEvent() {
        var early = PlaybackRecovery(now: 0, duration: 120)
        _ = early.observe(now: 10, mediaTime: 9, pictures: 90, state: .playing)
        guard case .retry = early.observe(now: 11, mediaTime: 9, pictures: 90, state: .ended).action else {
            return XCTFail("An early disconnect must not be treated as the end of the recording")
        }
        var boundary = PlaybackRecovery(now: 0, duration: 20)
        _ = boundary.observe(now: 20, mediaTime: 19, pictures: 190, state: .playing)
        XCTAssertEqual(boundary.observe(now: 24, mediaTime: 25, pictures: 190, state: .playing).action, .finished)
    }

    func testNextSegmentSkipsDuplicatesAndKeepsGapExplicit() throws {
        let base = Date(timeIntervalSince1970: 1000)
        let uri = try XCTUnwrap(URL(string: "rtsp://192.0.2.1/recording"))
        let first = Recording(start: base, end: base.addingTimeInterval(20), playbackURI: uri)
        let next = Recording(start: base.addingTimeInterval(30), end: base.addingTimeInterval(50), playbackURI: uri)
        let target = try XCTUnwrap(RecordingTimeline.next(after: first, recordings: [first, first, next]))
        XCTAssertEqual(target.recording, next)
        XCTAssertEqual(target.time, next.start)
        XCTAssertNil(RecordingTimeline.next(after: next, recordings: [first, next]))
    }

    func testLiveStreamRetriesSlowStartupAndReconnectsAfterEnd() {
        var recovery = PlaybackRecovery(now: 0, duration: nil, finishOnEnded: false, startupGrace: 12)
        XCTAssertEqual(recovery.observe(now: 11, mediaTime: 0, pictures: 0, state: .buffering).action, .none)
        XCTAssertEqual(recovery.observe(now: 13, mediaTime: 0, pictures: 0, state: .buffering).action,
                       .retry(elapsed: 0, attempt: 1, cacheMilliseconds: 5000))
        _ = recovery.observe(now: 14, mediaTime: 1, pictures: 10, state: .playing)
        XCTAssertEqual(recovery.observe(now: 15, mediaTime: 1, pictures: 10, state: .ended).action,
                       .retry(elapsed: 0, attempt: 2, cacheMilliseconds: 7000))
    }
}
