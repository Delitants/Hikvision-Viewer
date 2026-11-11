import Foundation
import SQLite3

public struct Camera: Codable, Hashable, Identifiable {
    public let id: String
    public let recorderID: String
    public let name: String
    public let channelNumber: Int
}

public struct Recorder: Codable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let host: String
    public let username: String
    public let httpPort: Int
    public let rtspPort: Int
    public let useHTTPS: Bool
    public let cameras: [Camera]
}

public enum StreamQuality: Int {
    case main = 1
    case sub = 2
}

public struct Recording: Hashable, Identifiable {
    public var id: String { playbackURI.absoluteString }
    public let start: Date
    public let end: Date
    public let playbackURI: URL
}

public enum LegacyImporter {
    public enum ImportError: Error { case cannotOpenDatabase, invalidQuery }

    public static func load(from path: String) throws -> [Recorder] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw ImportError.cannotOpenDatabase
        }
        defer { sqlite3_close(db) }

        func rows(_ query: String, columns: Int) throws -> [[String]] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw ImportError.invalidQuery
            }
            defer { sqlite3_finalize(statement) }
            var result: [[String]] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append((0..<columns).map { column in
                    guard let value = sqlite3_column_text(statement, Int32(column)) else { return "" }
                    return String(cString: value)
                })
            }
            return result
        }

        let deviceRows = try rows("SELECT GUID, Name, LoginAddress FROM HikDevice ORDER BY Name", columns: 3)
        let channelRows = try rows("SELECT GUID, DeviceGUID, Name, ChannelNo FROM Channel WHERE ChannelType IN (1,2) ORDER BY ChannelNo", columns: 4)
        let entityPath = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("Entity").path
        var aliases: [String: String] = [:]
        if FileManager.default.fileExists(atPath: entityPath) {
            var entityDB: OpaquePointer?
            if sqlite3_open_v2(entityPath, &entityDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let entityDB {
                var statement: OpaquePointer?
                if sqlite3_prepare_v2(entityDB, "SELECT ChannelGUID, Name FROM Camera", -1, &statement, nil) == SQLITE_OK,
                   let statement {
                    while sqlite3_step(statement) == SQLITE_ROW {
                        if let id = sqlite3_column_text(statement, 0), let name = sqlite3_column_text(statement, 1) {
                            let value = String(cString: name)
                            if !value.isEmpty { aliases[String(cString: id)] = value }
                        }
                    }
                    sqlite3_finalize(statement)
                }
                sqlite3_close(entityDB)
            } else if let entityDB { sqlite3_close(entityDB) }
        }
        let cameras = channelRows.compactMap { row -> Camera? in
            guard let number = Int(row[3]), number > 0 else { return nil }
            return Camera(id: row[0], recorderID: row[1], name: aliases[row[0]] ?? row[2], channelNumber: number)
        }.sorted { left, right in
            let leftNamed = aliases[left.id] != nil
            let rightNamed = aliases[right.id] != nil
            if leftNamed != rightNamed { return leftNamed }
            return left.channelNumber < right.channelNumber
        }
        return deviceRows.compactMap { row -> Recorder? in
            guard !row[0].isEmpty, !row[2].isEmpty else { return nil }
            return Recorder(id: row[0], name: row[1], host: row[2], username: "", httpPort: 80, rtspPort: 554, useHTTPS: false,
                            cameras: cameras.filter { $0.recorderID == row[0] })
        }
    }
}

public enum CameraURLs {
    public static func live(host: String, port: Int, channel: Int, quality: StreamQuality, username: String, password: String) -> URL? {
        guard channel > 0, channel < 1_000, (1...65535).contains(port), !host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "rtsp"
        components.host = host
        components.port = port
        components.path = "/Streaming/Channels/\(channel * 100 + quality.rawValue)"
        components.user = username
        components.password = password
        return components.url
    }

    public static func authenticated(_ url: URL, expectedHost: String, username: String, password: String, port: Int) -> URL? {
        guard (1...65535).contains(port), var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "rtsp",
              components.host?.lowercased() == expectedHost.lowercased() else { return nil }
        components.port = port
        components.user = username
        components.password = password
        return components.url
    }
}

public enum RecordingSearch {
    public enum ParseError: Error { case invalidXML }

    public static func request(channel: Int, start: Date, end: Date, position: Int = 0) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)!
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <CMSearchDescription>
        <searchID>\(UUID().uuidString)</searchID>
        <trackIDList><trackID>\(channel * 100 + 1)</trackID></trackIDList>
        <timeSpanList><timeSpan><startTime>\(formatter.string(from: start))</startTime><endTime>\(formatter.string(from: end))</endTime></timeSpan></timeSpanList>
        <maxResults>100</maxResults>
        <searchResultPosition>\(max(0, position))</searchResultPosition>
        <metadataList><metadataDescriptor>//recordType.meta.std-cgi.com</metadataDescriptor></metadataList>
        </CMSearchDescription>
        """
        return Data(xml.utf8)
    }

    public static func parse(_ data: Data) throws -> [Recording] {
        let delegate = SearchParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw ParseError.invalidXML }
        return delegate.recordings
    }
}

private final class SearchParser: NSObject, XMLParserDelegate {
    var recordings: [Recording] = []
    private var insideMatch = false
    private var currentTag = ""
    private var text = ""
    private var start = ""
    private var end = ""
    private var uri = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let tag = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if tag == "searchMatchItem" {
            insideMatch = true
            start = ""
            end = ""
            uri = ""
        }
        currentTag = tag
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let tag = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if insideMatch {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch tag {
            case "startTime": start = value
            case "endTime": end = value
            case "playbackURI": uri = value
            case "searchMatchItem":
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                if let from = formatter.date(from: start), let to = formatter.date(from: end), let url = URL(string: uri) {
                    recordings.append(Recording(start: from, end: to, playbackURI: url))
                }
                insideMatch = false
            default: break
            }
        }
        currentTag = ""
        text = ""
    }
}
