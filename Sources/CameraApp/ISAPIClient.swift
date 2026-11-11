import Foundation

enum ISAPIError: LocalizedError {
    case invalidAddress
    case unauthorized
    case http(Int)
    case insecureAuthentication

    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "The recorder address or port is invalid."
        case .unauthorized: return "The recorder rejected the username or password."
        case .http(let code): return "The recorder returned HTTP \(code)."
        case .insecureAuthentication: return "The recorder only offers Basic authentication over HTTP. Use HTTPS for this recorder."
        }
    }
}

private final class RecorderAuth: NSObject, URLSessionTaskDelegate {
    let username: String
    let password: String
    private(set) var refusedBasic = false

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        let secure = challenge.protectionSpace.protocol?.lowercased() == "https"
        if method == NSURLAuthenticationMethodHTTPDigest || (secure && method == NSURLAuthenticationMethodHTTPBasic) {
            completionHandler(.useCredential, URLCredential(user: username, password: password, persistence: .forSession))
        } else {
            if method == NSURLAuthenticationMethodHTTPBasic && !secure { refusedBasic = true }
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

enum ISAPIClient {
    static func search(recorder: Recorder, camera: Camera, password: String, on day: Date) async throws -> [Recording] {
        guard !recorder.host.isEmpty, (1...65535).contains(recorder.httpPort) else { throw ISAPIError.invalidAddress }
        var components = URLComponents()
        components.scheme = recorder.useHTTPS ? "https" : "http"
        components.host = recorder.host
        components.port = recorder.httpPort
        components.path = "/ISAPI/ContentMgmt/search"
        guard let url = components.url else { throw ISAPIError.invalidAddress }

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { throw ISAPIError.invalidAddress }
        let auth = RecorderAuth(username: recorder.username, password: password)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: auth, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var all: [Recording] = []
        for position in stride(from: 0, through: 900, by: 100) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
            request.httpBody = RecordingSearch.request(channel: camera.channelNumber, start: start, end: end, position: position)
            let (data, response): (Data, URLResponse)
            do { (data, response) = try await session.data(for: request) }
            catch {
                if auth.refusedBasic { throw ISAPIError.insecureAuthentication }
                throw error
            }
            guard let http = response as? HTTPURLResponse else { throw ISAPIError.invalidAddress }
            if http.statusCode == 401 { throw ISAPIError.unauthorized }
            guard http.statusCode == 200 else {
                do { _ = try RecordingSearch.parse(data) }
                catch let error as RecordingSearch.ParseError {
                    if case .device = error { throw error }
                } catch {}
                throw ISAPIError.http(http.statusCode)
            }
            let batch = try RecordingSearch.parse(data)
            all.append(contentsOf: batch)
            if batch.count < 100 { break }
        }
        return Array(Set(all)).sorted { $0.start < $1.start }
    }
}
