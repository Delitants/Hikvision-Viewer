import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var state = AppState()
    @State private var credentialRecorder: Recorder?
    @State private var settingsRecorder: Recorder?
    @State private var editingDevice: Recorder?
    @State private var pendingRemoval: Recorder?
    @State private var showingCalendar = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 260)
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                if state.mode == .live { liveView }
                else if state.mode == .recordings { recordingsView }
                else { devicesView }
                Divider()
                HStack {
                    Image(systemName: "info.circle")
                    Text(state.status).lineLimit(2)
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(10)
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        .sheet(item: $credentialRecorder) { recorder in
            CredentialsSheet(recorder: recorder) { username, password in
                Task {
                    do {
                        try await state.saveCredentials(username: username, password: password, for: recorder)
                        credentialRecorder = nil
                        if state.mode == .live, let camera = state.selectedCamera { state.show(camera) }
                        else if state.mode == .recordings { await state.search() }
                        else { await state.refreshChannels(for: recorder) }
                    } catch {
                        state.status = error.localizedDescription
                    }
                }
            } onCancel: { credentialRecorder = nil }
        }
        .sheet(item: $settingsRecorder) { recorder in
            RecorderSettingsSheet(recorder: recorder) { updated in
                state.updateRecorder(updated)
                settingsRecorder = nil
            } onCancel: { settingsRecorder = nil }
        }
        .sheet(item: $editingDevice) { recorder in
            DeviceEditorSheet(recorder: recorder) { updated in
                if state.recorders.contains(where: { $0.id == updated.id }) { state.updateRecorder(updated) }
                else { state.addDevice(updated) }
                editingDevice = nil
            } onCancel: { editingDevice = nil }
        }
        .confirmationDialog("Remove this device?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })) {
            Button("Remove Device", role: .destructive) {
                if let pendingRemoval { state.removeDevice(pendingRemoval.id) }
                pendingRemoval = nil
            }
        }
        .onDisappear { state.stopAll() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "video.fill")
                    .foregroundStyle(.tint)
                Text("Cameras").font(.headline)
                Spacer()
            }
            .padding(14)
            List {
                ForEach(state.recorders) { recorder in
                    Section {
                        ForEach(recorder.cameras) { camera in
                            Button {
                                if state.mode == .devices { state.setMode(.live) }
                                state.selectedCamera = camera
                                Task {
                                    if await state.hasPassword(for: camera) {
                                        if state.selectedCamera?.id == camera.id { state.show(camera) }
                                    } else if state.selectedCamera?.id == camera.id {
                                        credentialRecorder = recorder
                                    }
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "video")
                                        .frame(width: 18)
                                    Text(camera.name.isEmpty ? "Channel \(camera.channelNumber)" : camera.name)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 2)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(state.selectedCamera?.id == camera.id ? Color.accentColor.opacity(0.16) : Color.clear)
                        }
                    } header: {
                        HStack {
                            Text(recorder.name.isEmpty ? "Recorder" : recorder.name)
                                .lineLimit(1)
                            Spacer()
                            Button { settingsRecorder = recorder } label: { Image(systemName: "gearshape") }
                                .buttonStyle(.borderless)
                                .help("Recorder settings")
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(state.selectedCamera?.name ?? "Hikvision Viewer")
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                if let camera = state.selectedCamera, let recorder = state.recorder(for: camera) {
                    Text(recorder.name).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Picker("View", selection: Binding(get: { state.mode }, set: { state.setMode($0) })) {
                ForEach(ViewMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 350)
            if let camera = state.selectedCamera, let recorder = state.recorder(for: camera) {
                Button { credentialRecorder = recorder } label: { Image(systemName: "key") }
                    .help("Recorder credentials")
            }
        }
        .padding(14)
    }

    private var liveView: some View {
        VStack(spacing: 10) {
            HStack {
                Picker("Layout", selection: Binding(get: { state.gridCount }, set: { state.setGrid($0) })) {
                    Text("Single").tag(1)
                    Text("Four cameras").tag(4)
                }
                .pickerStyle(.segmented)
                .frame(width: 225)
                Spacer()
                Button("Stop All", systemImage: "stop.fill") { state.stopLive() }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: state.gridCount == 1 ? 1 : 2), spacing: 8) {
                ForEach(0..<state.gridCount, id: \.self) { index in
                    ZStack(alignment: .bottomLeading) {
                        VLCVideoView(player: state.players[index])
                        if let camera = state.slots[index] {
                            Text(camera.name)
                                .font(.caption.weight(.medium))
                                .padding(6)
                                .background(.black.opacity(0.65))
                                .foregroundStyle(.white)
                                .padding(8)
                        } else {
                            Text("Select a camera")
                                .foregroundStyle(.white.opacity(0.75))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .background(.black)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(state.selectedTile == index ? Color.accentColor : Color.gray.opacity(0.35), lineWidth: 2))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                    .onTapGesture { state.selectedTile = index }
                }
            }
            .padding(14)
            Spacer(minLength: 0)
        }
    }

    private var recordingsView: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    showingCalendar = true
                } label: {
                    Label(dateRangeLabel, systemImage: "calendar")
                }
                .popover(isPresented: $showingCalendar) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Choose dates").font(.headline)
                        Text("Select one day or a range of up to 7 days.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack(alignment: .top, spacing: 18) {
                            DatePicker("From", selection: Binding(get: { state.startDate }, set: { state.setStartDate($0) }), displayedComponents: .date)
                                .datePickerStyle(.graphical)
                            DatePicker("To", selection: Binding(get: { state.endDate }, set: { state.setEndDate($0) }),
                                       in: state.startDate...(Calendar.current.date(byAdding: .day, value: 6, to: state.startDate) ?? state.startDate),
                                       displayedComponents: .date)
                                .datePickerStyle(.graphical)
                        }
                        Button("Done") { showingCalendar = false }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding(18)
                }
                Button("Search") {
                    guard let camera = state.selectedCamera, let recorder = state.recorder(for: camera) else { return }
                    Task {
                        if await state.hasPassword(for: camera) { await state.search() }
                        else { credentialRecorder = recorder }
                    }
                }
                .disabled(state.selectedCamera == nil || state.isSearching)
                if state.isSearching { ProgressView().controlSize(.small) }
                Spacer()
                Button("Open Video…") { openLocalVideo() }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            VLCVideoView(player: state.playbackPlayer)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .padding(.horizontal, 14)

            HStack {
                Text("Recordings").font(.headline)
                Spacer()
                Button("Play", systemImage: "play.fill") { state.play(at: state.selectedTime) }
                    .disabled(state.recordings.isEmpty)
                Button("Stop", systemImage: "stop.fill") { state.playbackPlayer.stop() }
            }
            .padding(.horizontal, 14)
            RecordingTimelineView(start: state.startDate, end: state.timelineEnd, recordings: state.recordings,
                                  selectedTime: $state.selectedTime, onSeek: { state.play(at: $0) })
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
        }
    }

    private var dateRangeLabel: String {
        let start = state.startDate.formatted(date: .abbreviated, time: .omitted)
        if Calendar.current.isDate(state.startDate, inSameDayAs: state.endDate) { return start }
        return "\(start) – \(state.endDate.formatted(date: .abbreviated, time: .omitted))"
    }

    private func newDevice(host: String = "") -> Recorder {
        let id = UUID().uuidString
        return Recorder(id: id, name: "New Device", host: host, username: "admin", httpPort: 80,
                        rtspPort: 554, useHTTPS: false,
                        cameras: [Camera(id: "manual-\(id)-1", recorderID: id, name: "Camera 1", channelNumber: 1)])
    }

    private var devicesView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Devices").font(.title2.weight(.semibold))
                Spacer()
                Button("Search LAN") { Task { await state.discover() } }.disabled(state.isDiscovering)
                Button("Add Device") { editingDevice = newDevice() }
            }
            if state.isDiscovering { ProgressView("Searching for ONVIF cameras and recorders…") }
            if !state.discoveredHosts.isEmpty {
                Text("Found on LAN").font(.headline)
                ForEach(state.discoveredHosts, id: \.self) { host in
                    HStack {
                        Text(host)
                        Spacer()
                        Button("Add…") { editingDevice = newDevice(host: host) }
                    }
                }
                Divider()
            }
            List {
                ForEach(state.recorders) { recorder in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(recorder.name).font(.headline)
                            Text("\(recorder.host) · \(recorder.cameras.count) cameras")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Camera Names") {
                            Task {
                                if let camera = recorder.cameras.first, await state.hasPassword(for: camera) {
                                    await state.refreshChannels(for: recorder)
                                } else { credentialRecorder = recorder }
                            }
                        }
                        Button("Edit") { editingDevice = recorder }
                        Button(role: .destructive) { pendingRemoval = recorder } label: { Image(systemName: "trash") }
                    }
                    .padding(.vertical, 4)
                }
            }
            Text("LAN search uses ONVIF discovery. Devices with discovery disabled can be added by address.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(18)
    }

    private func openLocalVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie]
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { state.openLocalVideo(url) }
    }
}

private struct CredentialsSheet: View {
    let recorder: Recorder
    let onSave: (String, String) -> Void
    let onCancel: () -> Void
    @State private var username: String
    @State private var password = ""

    init(recorder: Recorder, onSave: @escaping (String, String) -> Void, onCancel: @escaping () -> Void) {
        self.recorder = recorder
        self.onSave = onSave
        self.onCancel = onCancel
        _username = State(initialValue: recorder.username)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect to \(recorder.name)").font(.title2.weight(.semibold))
            Text("Enter the recorder account. The password is stored in your Mac Keychain.")
                .foregroundStyle(.secondary)
            Form {
                TextField("Username", text: $username)
                SecureField("Password", text: $password)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Connect") { onSave(username, password) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(username.isEmpty || password.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

private struct RecorderSettingsSheet: View {
    let recorder: Recorder
    let onSave: (Recorder) -> Void
    let onCancel: () -> Void
    @State private var name: String
    @State private var host: String
    @State private var username: String
    @State private var httpPort: String
    @State private var rtspPort: String
    @State private var useHTTPS: Bool

    init(recorder: Recorder, onSave: @escaping (Recorder) -> Void, onCancel: @escaping () -> Void) {
        self.recorder = recorder
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: recorder.name)
        _host = State(initialValue: recorder.host)
        _username = State(initialValue: recorder.username)
        _httpPort = State(initialValue: String(recorder.httpPort))
        _rtspPort = State(initialValue: String(recorder.rtspPort))
        _useHTTPS = State(initialValue: recorder.useHTTPS)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recorder Settings").font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $name)
                TextField("Address", text: $host)
                TextField("Username", text: $username)
                Toggle("Use HTTPS for recording search", isOn: $useHTTPS)
                TextField("HTTP(S) port", text: $httpPort)
                TextField("RTSP port", text: $rtspPort)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") {
                    guard let http = Int(httpPort), let rtsp = Int(rtspPort) else { return }
                    onSave(Recorder(id: recorder.id, name: name, host: host, username: username,
                                    httpPort: http, rtspPort: rtsp, useHTTPS: useHTTPS, cameras: recorder.cameras))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(host.isEmpty || !(1...65535).contains(Int(httpPort) ?? 0) || !(1...65535).contains(Int(rtspPort) ?? 0))
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
