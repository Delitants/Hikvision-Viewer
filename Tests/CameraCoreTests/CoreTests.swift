import Foundation
import SQLite3
import XCTest
@testable import CameraCore

final class CoreTests: XCTestCase {
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
