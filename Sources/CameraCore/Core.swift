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

public enum StreamQuality: Int, Hashable {
    case main = 1
    case sub = 2
}

public enum LiveBufferMode: Int, Hashable {
    case responsive = 3_000
    case smooth = 8_000

    public var initialCacheMilliseconds: Int { rawValue }
    public var startupGraceSeconds: TimeInterval {
        12 + Double(rawValue - LiveBufferMode.responsive.rawValue) / 1_000
    }

    public func cacheMilliseconds(forRetry attempt: Int) -> Int {
        max(rawValue, min(10_000, 3_000 + min(4, max(0, attempt)) * 2_000))
    }
}

public enum RecordingKind: String { case continuous, event, manual, unknown }

public struct Recording: Hashable, Identifiable {
    public var id: String { playbackURI.absoluteString }
    public let start: Date
    public let end: Date
    public let playbackURI: URL
    public let kind: RecordingKind

    public init(start: Date, end: Date, playbackURI: URL, kind: RecordingKind = .continuous) {
        self.start = start; self.end = end; self.playbackURI = playbackURI; self.kind = kind
    }
}

public enum RecordingWindow {
    public static func days(start: Date, end: Date, calendar: Calendar = .current) -> [Date]? {
        let first = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        guard first <= last else { return nil }
        var days: [Date] = []
        var day = first
        while day <= last {
            guard days.count < 7 else { return nil }
            days.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
        }
        return days
    }
}

public enum RecordingTimeline {
    public static func next(after current: Recording, recordings: [Recording]) -> (recording: Recording, time: Date)? {
        guard let next = recordings.sorted(by: { $0.start < $1.start }).first(where: { $0.end > current.end && $0.start >= current.start }) else { return nil }
        return (next, max(current.end, next.start))
    }

    public static func seekTarget(for time: Date, recordings: [Recording]) -> (recording: Recording, time: Date)? {
        let ordered = recordings.sorted { $0.start < $1.start }
        for recording in ordered {
            if time < recording.start { return (recording, recording.start) }
            if time < recording.end {
                return (recording, min(time, max(recording.start, recording.end.addingTimeInterval(-3))))
            }
        }
        guard let last = ordered.last else { return nil }
        return (last, max(last.start, last.end.addingTimeInterval(-3)))
    }
}

public struct PlaybackStreamSelection {
    public private(set) var quality: StreamQuality = .main
    private let main: URL
    private var recordedSubstream: URL?
    private var substreamRejected = false
    private var substreamDisplayedFrame = false

    public init(main: URL) { self.main = main }

    public mutating func setRecordedSubstream(_ url: URL) {
        guard !substreamRejected else { return }
        recordedSubstream = url
    }

    public mutating func displayedFrame() {
        if quality == .sub { substreamDisplayedFrame = true }
    }

    public mutating func rejectSubstream() {
        quality = .main
        substreamRejected = true
        recordedSubstream = nil
    }

    public mutating func retry(elapsed: TimeInterval, attempt: Int) -> URL? {
        if quality == .sub && !substreamDisplayedFrame { rejectSubstream() }
        else if quality == .main && !substreamRejected && attempt >= 2 && recordedSubstream != nil {
            quality = .sub
            substreamDisplayedFrame = false
        }
        let source = quality == .sub ? (recordedSubstream ?? main) : main
        if elapsed == 0 { return source }
        if let resumed = RecordingPlayback.resume(source, elapsedSeconds: elapsed) { return resumed }
        if quality == .sub {
            rejectSubstream()
            return RecordingPlayback.resume(main, elapsedSeconds: elapsed)
        }
        return nil
    }
}

public struct LiveStreamSelection {
    public private(set) var quality: StreamQuality
    private let main: URL
    private let sub: URL?
    private var displayedFrameSinceRetry = false

    public init(main: URL, sub: URL?) {
        self.main = main
        self.sub = sub
        quality = sub == nil ? .main : .sub
    }

    public var url: URL { quality == .sub ? (sub ?? main) : main }

    public mutating func displayedFrame() { displayedFrameSinceRetry = true }

    public mutating func retry(attempt: Int) -> URL {
        if quality == .sub && (!displayedFrameSinceRetry || attempt >= 2) { quality = .main }
        displayedFrameSinceRetry = false
        return url
    }
}

public enum RecordingPlayback {
    public static func duration(_ url: URL) -> TimeInterval? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let start = items.first(where: { $0.name.lowercased() == "starttime" })?.value,
              let end = items.first(where: { $0.name.lowercased() == "endtime" })?.value else { return nil }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        guard let from = format.date(from: start), let through = format.date(from: end), through > from else { return nil }
        return through.timeIntervalSince(from)
    }

    public static func resume(_ url: URL, elapsedSeconds: TimeInterval) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              var items = parts.queryItems,
              let start = items.first(where: { $0.name.lowercased() == "starttime" })?.value,
              let end = items.first(where: { $0.name.lowercased() == "endtime" })?.value else { return nil }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        guard let from = format.date(from: start), let through = format.date(from: end),
              elapsedSeconds > 0, from.addingTimeInterval(elapsedSeconds + 2) < through else { return nil }
        let resumed = format.string(from: from.addingTimeInterval(elapsedSeconds))
        items = items.map { $0.name.lowercased() == "starttime" ? URLQueryItem(name: $0.name, value: resumed) : $0 }
        parts.queryItems = items
        return parts.url
    }
}

public struct DetectedChannel: Equatable {
    public let number: Int
    public let name: String
}

public enum StreamingChannels {
    public static func parse(_ data: Data) throws -> [DetectedChannel] {
        let delegate = StreamingChannelParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw RecordingSearch.ParseError.invalidXML }
        return delegate.channels.sorted { $0.number < $1.number }
    }
}

private final class StreamingChannelParser: NSObject, XMLParserDelegate {
    var channels: [DetectedChannel] = []
    private var inside = false
    private var tag = ""
    private var value = ""
    private var id = 0
    private var name = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        tag = elementName.split(separator: ":").last.map(String.init) ?? elementName
        value = ""
        if tag == "StreamingChannel" { inside = true; id = 0; name = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { value += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let ending = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if inside {
            if ending == "id", id == 0 { id = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
            if ending == "channelName" { name = value.trimmingCharacters(in: .whitespacesAndNewlines) }
            if ending == "StreamingChannel" {
                if id > 0, id % 100 == 1 {
                    let number = id / 100
                    channels.append(DetectedChannel(number: number, name: name.isEmpty ? "Channel \(number)" : name))
                }
                inside = false
            }
        }
        tag = ""; value = ""
    }
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

        let deviceColumns = Set(try rows("PRAGMA table_info(HikDevice)", columns: 2).map { $0[1] })
        func deviceColumn(_ name: String) -> String { deviceColumns.contains(name) ? "COALESCE(\(name), 0)" : "0" }
        let deviceRows = try rows("SELECT GUID, Name, LoginAddress, \(deviceColumn("AChanStartNo")), \(deviceColumn("DChanStartNo")), \(deviceColumn("AChanCount")), \(deviceColumn("DChanCount")) FROM HikDevice ORDER BY Name", columns: 7)
        let channelRows = try rows("SELECT GUID, DeviceGUID, Name, ChannelNo FROM Channel WHERE ChannelType = 1 ORDER BY ChannelNo", columns: 4)
        var layouts: [String: (analogStart: Int, digitalStart: Int, analogCount: Int, digitalCount: Int)] = [:]
        for row in deviceRows {
            layouts[row[0]] = (Int(row[3]) ?? 0, Int(row[4]) ?? 0, Int(row[5]) ?? 0, Int(row[6]) ?? 0)
        }
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
            var recorderChannel = number
            if let layout = layouts[row[1]] {
                if layout.digitalStart > 0, layout.digitalCount > 0,
                   (layout.digitalStart..<(layout.digitalStart + layout.digitalCount)).contains(number) {
                    recorderChannel = layout.analogCount + number - layout.digitalStart + 1
                } else if layout.analogStart > 0, layout.analogCount > 0,
                          (layout.analogStart..<(layout.analogStart + layout.analogCount)).contains(number) {
                    recorderChannel = number - layout.analogStart + 1
                }
            }
            return Camera(id: row[0], recorderID: row[1], name: aliases[row[0]] ?? row[2], channelNumber: recorderChannel)
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
    private static let credentialCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func setCredentials(_ components: inout URLComponents, username: String, password: String) {
        components.percentEncodedUser = username.addingPercentEncoding(withAllowedCharacters: credentialCharacters)
        components.percentEncodedPassword = password.addingPercentEncoding(withAllowedCharacters: credentialCharacters)
    }

    public static func live(host: String, port: Int, channel: Int, quality: StreamQuality, username: String, password: String) -> URL? {
        guard channel > 0, channel < 1_000, (1...65535).contains(port), !host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "rtsp"
        components.host = host
        components.port = port
        components.path = "/Streaming/Channels/\(channel * 100 + quality.rawValue)"
        setCredentials(&components, username: username, password: password)
        return components.url
    }

    public static func authenticated(_ url: URL, expectedHost: String, username: String, password: String, port: Int) -> URL? {
        guard (1...65535).contains(port), var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "rtsp",
              components.host?.lowercased() == expectedHost.lowercased() else { return nil }
        components.port = port
        setCredentials(&components, username: username, password: password)
        return components.url
    }
}

public enum RecordingSearch {
    public enum ParseError: LocalizedError {
        case invalidXML
        case device(String)

        public var errorDescription: String? {
            switch self {
            case .invalidXML: return "The recorder returned invalid XML."
            case .device(let detail): return "Recorder search error: \(detail)"
            }
        }
    }

    public static func request(channel: Int, start: Date, end: Date, position: Int = 0,
                               quality: StreamQuality = .main) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)!
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <CMSearchDescription>
        <searchID>\(UUID().uuidString)</searchID>
        <trackIDList><trackID>\(channel * 100 + quality.rawValue)</trackID></trackIDList>
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
        if delegate.isResponseStatus { throw ParseError.device(delegate.responseDetail) }
        return delegate.recordings
    }
}

private final class SearchParser: NSObject, XMLParserDelegate {
    var recordings: [Recording] = []
    var isResponseStatus = false
    private var statusString = ""
    private var subStatusCode = ""
    var responseDetail: String {
        if statusString.isEmpty { return subStatusCode.isEmpty ? "The recorder rejected the request." : subStatusCode }
        if subStatusCode.isEmpty || subStatusCode == statusString { return statusString }
        return "\(statusString) (\(subStatusCode))"
    }
    private var insideMatch = false
    private var currentTag = ""
    private var text = ""
    private var start = ""
    private var end = ""
    private var uri = ""
    private var kind: RecordingKind = .continuous

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let tag = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if tag == "ResponseStatus" { isResponseStatus = true }
        if tag == "searchMatchItem" {
            insideMatch = true
            start = ""
            end = ""
            uri = ""
            kind = .continuous
        }
        currentTag = tag
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let tag = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if isResponseStatus {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch tag {
            case "statusString": statusString = String(value.prefix(120))
            case "subStatusCode": subStatusCode = String(value.prefix(120))
            default: break
            }
        }
        if insideMatch {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch tag {
            case "startTime": start = value
            case "endTime": end = value
            case "playbackURI": uri = value
            case "metadataDescriptor":
                let descriptor = value.lowercased()
                if descriptor.contains("manual") { kind = .manual }
                else if ["motion", "alarm", "event", "vca"].contains(where: descriptor.contains) { kind = .event }
                else if descriptor.contains("timing") || descriptor.contains("continuous") { kind = .continuous }
                else { kind = .unknown }
            case "searchMatchItem":
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                if let from = formatter.date(from: start), let to = formatter.date(from: end), let url = URL(string: uri) {
                    recordings.append(Recording(start: from, end: to, playbackURI: url, kind: kind))
                }
                insideMatch = false
            default: break
            }
        }
        currentTag = ""
        text = ""
    }
}
