import SwiftUI

private struct CameraDraft: Identifiable {
    let id: String
    var name: String
    var number: String
}

struct DeviceEditorSheet: View {
    let recorder: Recorder
    let onSave: (Recorder) -> Void
    let onCancel: () -> Void
    @State private var name: String
    @State private var host: String
    @State private var username: String
    @State private var httpPort: String
    @State private var rtspPort: String
    @State private var useHTTPS: Bool
    @State private var cameras: [CameraDraft]

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
        _cameras = State(initialValue: recorder.cameras.map {
            CameraDraft(id: $0.id, name: $0.name, number: String($0.channelNumber))
        })
    }

    private var valid: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty &&
        (1...65535).contains(Int(httpPort) ?? 0) && (1...65535).contains(Int(rtspPort) ?? 0) &&
        !cameras.isEmpty && cameras.allSatisfy { (1...999).contains(Int($0.number) ?? 0) } &&
        Set(cameras.compactMap { Int($0.number) }).count == cameras.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Device Configuration").font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $name)
                TextField("Address", text: $host)
                TextField("Username", text: $username)
                Toggle("Use HTTPS for recording search", isOn: $useHTTPS)
                TextField("HTTP(S) port", text: $httpPort)
                TextField("RTSP port", text: $rtspPort)
            }
            HStack {
                Text("Cameras").font(.headline)
                Spacer()
                Button("Add Camera") {
                    let next = (cameras.compactMap { Int($0.number) }.max() ?? 0) + 1
                    cameras.append(CameraDraft(id: "manual-\(recorder.id)-\(next)", name: "Camera \(next)", number: String(next)))
                }
            }
            ScrollView {
                VStack {
                    ForEach($cameras) { $camera in
                        HStack {
                            TextField("Camera name", text: $camera.name)
                            TextField("Channel", text: $camera.number).frame(width: 75)
                            Button { cameras.removeAll { $0.id == camera.id } } label: { Image(systemName: "minus.circle") }
                        }
                    }
                }
            }
            .frame(maxHeight: 170)
            Text("NVR channels can also be retrieved from the device after connecting.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") {
                    let entries = cameras.compactMap { row -> Camera? in
                        guard let number = Int(row.number) else { return nil }
                        return Camera(id: row.id, recorderID: recorder.id, name: row.name, channelNumber: number)
                    }
                    onSave(Recorder(id: recorder.id, name: name.isEmpty ? host : name,
                                    host: host.trimmingCharacters(in: .whitespaces), username: username,
                                    httpPort: Int(httpPort) ?? 80, rtspPort: Int(rtspPort) ?? 554,
                                    useHTTPS: useHTTPS, cameras: entries))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
        }
        .padding(22)
        .frame(width: 560)
    }
}
