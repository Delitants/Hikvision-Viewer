import Foundation

@main struct ISAPIIntegration {
    static func main() async throws {
        let camera = Camera(id: "c1", recorderID: "r1", name: "Front Gate", channelNumber: 1)
        let recorder = Recorder(id: "r1", name: "Test", host: "127.0.0.1", username: "viewer",
                                httpPort: 18765, rtspPort: 554, useHTTPS: false, cameras: [camera])
        let recordings = try await ISAPIClient.search(recorder: recorder, camera: camera,
                                                       password: "testpass", on: Date())
        guard recordings.count == 1,
              recordings[0].playbackURI.path == "/Streaming/tracks/101" else {
            throw NSError(domain: "HikvisionViewer", code: 1)
        }
        print("ISAPI Digest search returned one recording")
    }
}
