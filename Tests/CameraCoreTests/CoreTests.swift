import Foundation
import SQLite3
import XCTest
@testable import CameraCore

final class CoreTests: XCTestCase {
    func testRecordingWindowAcceptsSevenCalendarDaysAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Madrid"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 27, hour: 12)))
        let end = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 2, hour: 9)))
        let days = try XCTUnwrap(RecordingWindow.days(start: start, end: end, calendar: calendar))
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(calendar.component(.day, from: days[2]), 29)
        XCTAssertEqual(calendar.component(.day, from: days[6]), 2)
    }

    func testRecordingWindowRejectsEighthDayAndReverseRange() throws {
        let calendar = Calendar(identifier: .gregorian)
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1)))
        let eighth = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 8)))
        XCTAssertNil(RecordingWindow.days(start: start, end: eighth, calendar: calendar))
        XCTAssertNil(RecordingWindow.days(start: eighth, end: start, calendar: calendar))
        XCTAssertEqual(RecordingWindow.days(start: start, end: start, calendar: calendar)?.count, 1)
    }

    func testTimelineSeeksInsideFootageOrToNextSegment() throws {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let url = try XCTUnwrap(URL(string: "rtsp://192.0.2.1/Streaming/tracks/101"))
        let first = Recording(start: base, end: base.addingTimeInterval(60), playbackURI: url)
        let second = Recording(start: base.addingTimeInterval(120), end: base.addingTimeInterval(180), playbackURI: url)
        let recordings = [first, second]
        XCTAssertEqual(RecordingTimeline.seekTarget(for: base.addingTimeInterval(20), recordings: recordings)?.time,
                       base.addingTimeInterval(20))
        XCTAssertEqual(RecordingTimeline.seekTarget(for: base.addingTimeInterval(90), recordings: recordings)?.time,
                       second.start)
        XCTAssertEqual(RecordingTimeline.seekTarget(for: base.addingTimeInterval(-20), recordings: recordings)?.time,
                       first.start)
    }

    func testTimelineClampsAfterLastSegmentToPlayableTime() throws {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let url = try XCTUnwrap(URL(string: "rtsp://192.0.2.1/Streaming/tracks/101"))
        let recording = Recording(start: base, end: base.addingTimeInterval(60), playbackURI: url)
        let target = try XCTUnwrap(RecordingTimeline.seekTarget(for: base.addingTimeInterval(200), recordings: [recording]))
        XCTAssertEqual(target.recording, recording)
        XCTAssertEqual(target.time, base.addingTimeInterval(57))
        XCTAssertNil(RecordingTimeline.seekTarget(for: base, recordings: []))
    }

    func testResumeRecordingKeepsEndAndAdvancesStart() throws {
        let original = try XCTUnwrap(URL(string: "rtsp://192.0.2.1/Streaming/tracks/101?starttime=20261110T100000Z&endtime=20261110T110000Z"))
        let resumed = try XCTUnwrap(RecordingPlayback.resume(original, elapsedSeconds: 75))
        XCTAssertTrue(resumed.absoluteString.contains("starttime=20261110T100115Z"))
        XCTAssertTrue(resumed.absoluteString.contains("endtime=20261110T110000Z"))
    }

    func testStreamingChannelParserUsesMainStreamsAndNames() throws {
        let xml = """
        <StreamingChannelList><StreamingChannel><id>101</id><channelName>Front</channelName></StreamingChannel><StreamingChannel><id>102</id><channelName>Front sub</channelName></StreamingChannel><StreamingChannel><id>201</id><channelName>Back</channelName></StreamingChannel></StreamingChannelList>
        """
        let channels = try StreamingChannels.parse(Data(xml.utf8))
        XCTAssertEqual(channels.map(\.number), [1, 2])
        XCTAssertEqual(channels.map(\.name), ["Front", "Back"])
    }
    func testImportsSavedRecordersAndChannelsWithoutPasswords() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE HikDevice (GUID TEXT, Name TEXT, LoginAddress TEXT, LoginPort INTEGER, UserName TEXT, UserPwd TEXT);
        CREATE TABLE Channel (GUID TEXT, DeviceGUID TEXT, Name TEXT, ChannelType INTEGER, ChannelNo INTEGER);
        INSERT INTO HikDevice VALUES ('r1','Recorder','192.0.2.1',8000,'operator','secret');
        INSERT INTO Channel VALUES ('c1','r1','Front',1,33);
        INSERT INTO Channel VALUES ('c2','r1','Back',1,34);
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        let result = try LegacyImporter.load(from: path)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.cameras.map(\.name), ["Front", "Back"])
        XCTAssertEqual(result.first?.host, "192.0.2.1")
        XCTAssertEqual(result.first?.username, "")
        XCTAssertFalse(String(describing: result).contains("secret"))
    }

    func testLiveURLUsesChannelAndEscapesCredentials() throws {
        let url = try XCTUnwrap(CameraURLs.live(host: "192.0.2.1", port: 554, channel: 33, quality: .sub, username: "u:ser", password: "p@ss?"))
        XCTAssertEqual(url.path, "/Streaming/Channels/3302")
        XCTAssertEqual(url.port, 554)
        XCTAssertEqual(url.user?.removingPercentEncoding, "u:ser")
        XCTAssertEqual(url.password?.removingPercentEncoding, "p@ss?")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.percentEncodedUser, "u%3Aser")
        XCTAssertEqual(components.percentEncodedPassword, "p%40ss%3F")
    }

    func testImportUsesAssignedCameraNamesFromEntityDatabase() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var device: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("Device").path, &device), SQLITE_OK)
        defer { sqlite3_close(device) }
        XCTAssertEqual(sqlite3_exec(device, "CREATE TABLE HikDevice (GUID TEXT, Name TEXT, LoginAddress TEXT, UserName TEXT); CREATE TABLE Channel (GUID TEXT, DeviceGUID TEXT, Name TEXT, ChannelType INTEGER, ChannelNo INTEGER); INSERT INTO HikDevice VALUES ('r1','Recorder','192.0.2.1','operator'); INSERT INTO Channel VALUES ('c1','r1','IP Camera1',1,33); INSERT INTO Channel VALUES ('c2','r1','IP Camera2',1,34);", nil, nil, nil), SQLITE_OK)
        var entity: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("Entity").path, &entity), SQLITE_OK)
        defer { sqlite3_close(entity) }
        XCTAssertEqual(sqlite3_exec(entity, "CREATE TABLE Camera (ChannelGUID TEXT, Name TEXT); INSERT INTO Camera VALUES ('c2','Front Gate');", nil, nil, nil), SQLITE_OK)

        let result = try LegacyImporter.load(from: directory.appendingPathComponent("Device").path)
        XCTAssertEqual(result.first?.cameras.first?.name, "Front Gate")
    }

    func testImportMapsDigitalSDKChannelsToRecorderStreams() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE HikDevice (GUID TEXT, Name TEXT, LoginAddress TEXT, AChanStartNo INTEGER, DChanStartNo INTEGER, AChanCount INTEGER, DChanCount INTEGER);
        CREATE TABLE Channel (GUID TEXT, DeviceGUID TEXT, Name TEXT, ChannelType INTEGER, ChannelNo INTEGER);
        INSERT INTO HikDevice VALUES ('r1','Recorder','192.0.2.1',1,33,0,32);
        INSERT INTO Channel VALUES ('c1','r1','Driveway',1,33);
        INSERT INTO Channel VALUES ('c2','r1','Garden',1,34);
        INSERT INTO Channel VALUES ('c0','r1','Channel-zero1',2,1);
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        let result = try LegacyImporter.load(from: path)
        XCTAssertEqual(result.first?.cameras.map(\.name), ["Driveway", "Garden"])
        XCTAssertEqual(result.first?.cameras.map(\.channelNumber), [1, 2])
    }

    func testSearchRequestUsesHikvisionTrackAndUTC() throws {
        let start = Date(timeIntervalSince1970: 0)
        let end = Date(timeIntervalSince1970: 3600)
        let xml = String(decoding: RecordingSearch.request(channel: 33, start: start, end: end), as: UTF8.self)
        XCTAssertTrue(xml.contains("<trackID>3301</trackID>"))
        XCTAssertTrue(xml.contains("<startTime>1970-01-01T00:00:00Z</startTime>"))
        XCTAssertTrue(xml.contains("<endTime>1970-01-01T01:00:00Z</endTime>"))
        XCTAssertTrue(xml.contains("<trackIDList><trackID>3301</trackID></trackIDList>"))
        XCTAssertTrue(xml.contains("<searchResultPosition>0</searchResultPosition>"))
        XCTAssertTrue(xml.contains("<metadataDescriptor>//recordType.meta.std-cgi.com</metadataDescriptor>"))
    }

    func testPlaybackURLNeverSendsCredentialsToAnotherHost() throws {
        let foreign = URL(string: "rtsp://other.example/Streaming/tracks/3301")!
        XCTAssertNil(CameraURLs.authenticated(foreign, expectedHost: "192.0.2.1", username: "operator", password: "secret", port: 554))
        let local = URL(string: "rtsp://192.0.2.1/Streaming/tracks/3301?starttime=20261110T100000Z")!
        let authenticated = try XCTUnwrap(CameraURLs.authenticated(local, expectedHost: "192.0.2.1", username: "u:ser", password: "p@ss?", port: 554))
        XCTAssertEqual(authenticated.host, "192.0.2.1")
        XCTAssertEqual(authenticated.port, 554)
        let components = try XCTUnwrap(URLComponents(url: authenticated, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.percentEncodedUser, "u%3Aser")
        XCTAssertEqual(components.percentEncodedPassword, "p%40ss%3F")
    }

    func testSearchParserReadsNamespacedRecording() throws {
        let xml = """
        <CMSearchResult xmlns="http://www.isapi.org/ver20/XMLSchema"><matchList><searchMatchItem>
        <timeSpan><startTime>2026-11-10T10:00:00Z</startTime><endTime>2026-11-10T10:05:00Z</endTime></timeSpan>
        <playbackURI>rtsp://192.0.2.1/Streaming/tracks/3301?starttime=20261110T100000Z&amp;endtime=20261110T100500Z</playbackURI>
        </searchMatchItem></matchList></CMSearchResult>
        """
        let recordings = try RecordingSearch.parse(Data(xml.utf8))
        XCTAssertEqual(recordings.count, 1)
        let first = try XCTUnwrap(recordings.first)
        XCTAssertEqual(first.end.timeIntervalSince(first.start), 300)
        XCTAssertTrue(first.playbackURI.absoluteString.contains("endtime=20261110T100500Z"))
    }

    func testSearchParserReportsRecorderErrorInsteadOfEmptyResults() throws {
        let xml = """
        <ResponseStatus xmlns="http://www.isapi.org/ver20/XMLSchema">
        <requestURL>/ISAPI/ContentMgmt/search</requestURL>
        <statusCode>6</statusCode>
        <statusString>Invalid XML Content</statusString>
        <subStatusCode>badXmlContent</subStatusCode>
        </ResponseStatus>
        """
        XCTAssertThrowsError(try RecordingSearch.parse(Data(xml.utf8))) { error in
            XCTAssertTrue(error.localizedDescription.contains("Invalid XML Content"))
            XCTAssertTrue(error.localizedDescription.contains("badXmlContent"))
        }
    }
}
