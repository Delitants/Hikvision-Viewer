import Foundation
import SwiftUI

enum ViewMode: String, CaseIterable, Identifiable {
    case live = "Live View"
    case recordings = "Recordings"
    var id: String { rawValue }
}

@MainActor final class AppState: ObservableObject {
    @Published var recorders: [Recorder] = []
    @Published var selectedCamera: Camera?
    @Published var mode: ViewMode = .live
    @Published var gridCount = 1
    @Published var selectedTile = 0
    @Published var slots: [Camera?] = Array(repeating: nil, count: 4)
    @Published var recordings: [Recording] = []
    @Published var searchDate = Date()
    @Published var isSearching = false
    @Published var status = "Select a camera to begin."

    let players: [VLCPlayer] = (0..<4).map { _ in VLCPlayer() }
    let playbackPlayer = VLCPlayer()
    private var passwords: [String: String] = [:]

    private static var settingsURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Camera View", isDirectory: true)
            .appendingPathComponent("recorders.json")
    }

    init() {
        do {
            let legacy = "/Applications/iVMS-4200.app/Contents/MacOS/Device"
            if FileManager.default.fileExists(atPath: Self.settingsURL.path) {
                recorders = try JSONDecoder().decode([Recorder].self, from: Data(contentsOf: Self.settingsURL))
                if let imported = try? LegacyImporter.load(from: legacy) {
                    let importedCameras = imported.flatMap(\.cameras)
                    let names = Dictionary(uniqueKeysWithValues: importedCameras.map { ($0.id, $0.name) })
                    let order = Dictionary(uniqueKeysWithValues: importedCameras.enumerated().map { ($0.element.id, $0.offset) })
                    recorders = recorders.map { recorder in
                        let cameras = recorder.cameras.map { camera in
                            Camera(id: camera.id, recorderID: camera.recorderID,
                                   name: names[camera.id] ?? camera.name, channelNumber: camera.channelNumber)
                        }.sorted { (order[$0.id] ?? Int.max) < (order[$1.id] ?? Int.max) }
                        return Recorder(id: recorder.id, name: recorder.name, host: recorder.host, username: recorder.username,
                                        httpPort: recorder.httpPort, rtspPort: recorder.rtspPort, useHTTPS: recorder.useHTTPS,
                                        cameras: cameras)
                    }
                    try persist()
                }
            } else {
                recorders = try LegacyImporter.load(from: legacy)
                try persist()
            }
            if recorders.isEmpty { status = "No cameras found in iVMS-4200." }
            else { selectedCamera = recorders.first?.cameras.first }
        } catch {
            status = "Could not import the saved iVMS-4200 camera list."
        }
        if !playbackPlayer.isAvailable { status = "Install VLC in /Applications to play video." }
    }

    func recorder(for camera: Camera) -> Recorder? { recorders.first { $0.id == camera.recorderID } }
    func hasPassword(for camera: Camera) async -> Bool {
        if passwords[camera.recorderID] != nil { return true }
        status = "Unlocking recorder password in Keychain…"
        let recorderID = camera.recorderID
        let password = await Task.detached(priority: .userInitiated) {
            SecretStore.password(for: recorderID)
        }.value
        if let password { passwords[recorderID] = password }
        return password != nil
    }

    func saveCredentials(username: String, password: String, for recorder: Recorder) async throws {
        let recorderID = recorder.id
        try await Task.detached(priority: .userInitiated) {
            try SecretStore.save(password, for: recorderID)
        }.value
        passwords[recorderID] = password
        let updated = Recorder(id: recorder.id, name: recorder.name, host: recorder.host, username: username,
                               httpPort: recorder.httpPort, rtspPort: recorder.rtspPort, useHTTPS: recorder.useHTTPS,
                               cameras: recorder.cameras)
        replace(updated)
    }

    func updateRecorder(_ recorder: Recorder) { replace(recorder) }

    private func replace(_ recorder: Recorder) {
        guard let index = recorders.firstIndex(where: { $0.id == recorder.id }) else { return }
        recorders[index] = recorder
        do { try persist() }
        catch { status = "Could not save recorder settings." }
    }

    private func persist() throws {
        let file = Self.settingsURL
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(recorders)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func setMode(_ mode: ViewMode) {
        self.mode = mode
        if mode == .recordings { stopLive() }
        else { playbackPlayer.stop() }
    }

    func setGrid(_ count: Int) {
        guard count == 1 || count == 4 else { return }
        gridCount = count
        selectedTile = 0
        if count == 1 {
            for index in 1..<4 { players[index].stop(); slots[index] = nil }
        }
        for index in 0..<count {
            if let camera = slots[index] { start(camera, in: index) }
        }
    }

    func show(_ camera: Camera) {
        selectedCamera = camera
        guard mode == .live else { return }
        start(camera, in: selectedTile)
        selectedTile = (selectedTile + 1) % gridCount
    }

    private func start(_ camera: Camera, in index: Int) {
        guard let recorder = recorder(for: camera), let password = passwords[recorder.id] else {
            status = "Enter the recorder password to play video."
            return
        }
        let quality: StreamQuality = gridCount == 1 ? .main : .sub
        guard let url = CameraURLs.live(host: recorder.host, port: recorder.rtspPort, channel: camera.channelNumber,
                                        quality: quality, username: recorder.username, password: password) else {
            status = "The recorder address is invalid."
            return
        }
        slots[index] = camera
        status = players[index].play(url) ? "Connecting to \(camera.name)…" : "Could not start the video player."
    }

    func stopLive() {
        players.forEach { $0.stop() }
    }

    func stopAll() {
        stopLive()
        playbackPlayer.stop()
    }

    func search() async {
        guard let camera = selectedCamera, let recorder = recorder(for: camera),
              let password = passwords[recorder.id] else {
            status = "Enter the recorder password to search recordings."
            return
        }
        isSearching = true
        recordings = []
        status = "Searching recordings…"
        defer { isSearching = false }
        do {
            let found = try await ISAPIClient.search(recorder: recorder, camera: camera, password: password, on: searchDate)
            recordings = found
            status = found.isEmpty ? "No recordings found for this date." : "Found \(found.count) recordings."
        } catch {
            status = error.localizedDescription
        }
    }

    func play(_ recording: Recording) {
        guard let camera = selectedCamera, let recorder = recorder(for: camera),
              let password = passwords[recorder.id],
              let url = CameraURLs.authenticated(recording.playbackURI, expectedHost: recorder.host,
                                                  username: recorder.username, password: password, port: recorder.rtspPort) else {
            status = "The recorder returned a playback address for a different host."
            return
        }
        status = playbackPlayer.play(url) ? "Playing recording…" : "Could not start playback."
    }

    func openLocalVideo(_ url: URL) {
        setMode(.recordings)
        status = playbackPlayer.play(url) ? "Playing local video." : "Could not open the video file."
    }
}
