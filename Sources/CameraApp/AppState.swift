import Foundation
import SwiftUI

enum ViewMode: String, CaseIterable, Identifiable {
    case live = "Live View"
    case recordings = "Recordings"
    case devices = "Devices"
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
    @Published var startDate = Calendar.current.startOfDay(for: Date())
    @Published var endDate = Calendar.current.startOfDay(for: Date())
    @Published var selectedTime = Date()
    @Published var isSearching = false
    @Published var isDiscovering = false
    @Published var discoveredHosts: [String] = []
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
                if !UserDefaults.standard.bool(forKey: "importedDigitalChannelMappingV1"),
                   let imported = try? LegacyImporter.load(from: legacy) {
                    let importedCameras = Dictionary(uniqueKeysWithValues: imported.map { ($0.id, $0.cameras) })
                    recorders = recorders.map { recorder in
                        return Recorder(id: recorder.id, name: recorder.name, host: recorder.host, username: recorder.username,
                                        httpPort: recorder.httpPort, rtspPort: recorder.rtspPort, useHTTPS: recorder.useHTTPS,
                                        cameras: importedCameras[recorder.id] ?? recorder.cameras)
                    }
                    try persist()
                    UserDefaults.standard.set(true, forKey: "importedDigitalChannelMappingV1")
                }
            } else {
                recorders = try LegacyImporter.load(from: legacy)
                try persist()
                UserDefaults.standard.set(true, forKey: "importedDigitalChannelMappingV1")
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

    func addDevice(_ recorder: Recorder) {
        guard !recorders.contains(where: { $0.host == recorder.host && $0.httpPort == recorder.httpPort }) else {
            status = "That device is already configured."
            return
        }
        recorders.append(recorder)
        try? persist()
        status = "Added \(recorder.name). Enter its credentials to retrieve camera names."
    }

    func removeDevice(_ id: String) {
        guard let index = recorders.firstIndex(where: { $0.id == id }) else { return }
        let device = recorders.remove(at: index)
        if selectedCamera?.recorderID == id { selectedCamera = nil; stopAll() }
        passwords[id] = nil
        try? persist()
        status = "Removed \(device.name)."
    }

    func refreshChannels(for recorder: Recorder) async {
        guard let current = recorders.first(where: { $0.id == recorder.id }),
              let password = passwords[recorder.id] else { return }
        do {
            let channels = try await ISAPIClient.channels(recorder: current, password: password)
            guard !channels.isEmpty else { status = "No camera channels were reported by this device."; return }
            let cameras = channels.map { channel in
                Camera(id: "manual-\(recorder.id)-\(channel.number)", recorderID: recorder.id,
                       name: channel.name, channelNumber: channel.number)
            }
            replace(Recorder(id: current.id, name: current.name, host: current.host, username: current.username,
                             httpPort: current.httpPort, rtspPort: current.rtspPort, useHTTPS: current.useHTTPS,
                             cameras: cameras))
            if selectedCamera?.recorderID == current.id {
                let selectedNumber = selectedCamera?.channelNumber
                selectedCamera = cameras.first(where: { $0.channelNumber == selectedNumber }) ?? cameras.first
            }
            status = "Retrieved \(cameras.count) camera names from \(current.name)."
        } catch { status = "Could not retrieve camera names: \(error.localizedDescription)" }
    }

    func discover() async {
        isDiscovering = true
        status = "Searching the LAN for ONVIF devices…"
        discoveredHosts = await LANDiscovery.search()
        isDiscovering = false
        status = discoveredHosts.isEmpty ? "No ONVIF devices found. You can add an address manually." : "Found \(discoveredHosts.count) devices."
    }

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
        if mode != .live { stopLive() }
        if mode != .recordings { playbackPlayer.stop() }
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

    var timelineEnd: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: endDate)) ?? endDate
    }

    func setStartDate(_ date: Date) {
        let calendar = Calendar.current
        startDate = calendar.startOfDay(for: date)
        let latest = calendar.date(byAdding: .day, value: 6, to: startDate) ?? startDate
        endDate = min(max(endDate, startDate), latest)
        selectedTime = startDate
        recordings = []
        playbackPlayer.stop()
        status = "Dates changed. Search recordings."
    }

    func setEndDate(_ date: Date) {
        let calendar = Calendar.current
        let latest = calendar.date(byAdding: .day, value: 6, to: startDate) ?? startDate
        endDate = min(max(calendar.startOfDay(for: date), startDate), latest)
        selectedTime = startDate
        recordings = []
        playbackPlayer.stop()
        status = "Dates changed. Search recordings."
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
            guard let days = RecordingWindow.days(start: startDate, end: endDate) else {
                status = "Choose no more than seven calendar days."
                return
            }
            var found: [Recording] = []
            for (index, day) in days.enumerated() {
                status = "Searching day \(index + 1) of \(days.count)…"
                found += try await ISAPIClient.search(recorder: recorder, camera: camera, password: password, on: day)
            }
            recordings = Array(Set(found)).sorted { $0.start < $1.start }
            selectedTime = recordings.first?.start ?? startDate
            status = recordings.isEmpty ? "No recordings found for this range." : "Found \(recordings.count) recording segments."
        } catch {
            status = error.localizedDescription
        }
    }

    func play(at time: Date) {
        guard let target = RecordingTimeline.seekTarget(for: time, recordings: recordings) else {
            status = "Search for recordings first."
            return
        }
        selectedTime = target.time
        let offset = target.time.timeIntervalSince(target.recording.start)
        let playbackURI = offset > 0 ? RecordingPlayback.resume(target.recording.playbackURI, elapsedSeconds: offset) : target.recording.playbackURI
        guard let playbackURI else {
            status = "This recorder cannot seek within that segment."
            return
        }
        guard let camera = selectedCamera, let recorder = recorder(for: camera),
              let password = passwords[recorder.id],
              let url = CameraURLs.authenticated(playbackURI, expectedHost: recorder.host,
                                                  username: recorder.username, password: password, port: recorder.rtspPort) else {
            status = "The recorder returned a playback address for a different host."
            return
        }
        playbackPlayer.onPlaybackTime = { [weak self] seconds in
            self?.selectedTime = min(target.time.addingTimeInterval(seconds), target.recording.end)
        }
        playbackPlayer.onRecovery = { [weak self] attempt in
            self?.status = "Connection interrupted. Resuming recording (attempt \(attempt))…"
        }
        playbackPlayer.onResumed = { [weak self] in
            self?.status = "Playback resumed."
        }
        status = playbackPlayer.play(url, recoverRecording: true) ? "Playing recording…" : "Could not start playback."
    }

    func openLocalVideo(_ url: URL) {
        setMode(.recordings)
        status = playbackPlayer.play(url) ? "Playing local video." : "Could not open the video file."
    }
}
