import AppKit
import SwiftUI

final class VLCEnvironment {
    static let shared = VLCEnvironment()
    let instance: OpaquePointer?

    private init() {
        let root = "/Applications/VLC.app/Contents/MacOS"
        let plugins = root + "/plugins"
        guard FileManager.default.fileExists(atPath: plugins) else {
            instance = nil
            return
        }
        setenv("VLC_PLUGIN_PATH", plugins, 1)
        instance = libvlc_new(0, nil)
    }

    deinit {
        if let instance { libvlc_release(instance) }
    }
}

private enum VLCReaper {
    static let queue = DispatchQueue(label: "HikvisionViewer.VLC.cleanup", qos: .utility)

    static func retire(_ player: OpaquePointer) {
        let address = UInt(bitPattern: player)
        queue.async {
            guard let pointer = OpaquePointer(bitPattern: address) else { return }
            libvlc_media_player_stop(pointer)
            libvlc_media_player_release(pointer)
        }
    }
}

@MainActor final class VLCPlayer: ObservableObject {
    private var player: OpaquePointer?
    private weak var view: NSView?
    private var monitor: Timer?
    private var recordingURL: URL?
    private var elapsedOffset: TimeInterval = 0
    private var lastTime: Int64 = -1
    private var lastPictures: Int32 = -1
    private var hasProgress = false
    private var lastProgress = Date()
    private var segmentStarted = Date()
    private var lastRetry = Date.distantPast
    private var retries = 0
    private var recovering = false
    var onRecovery: ((Int) -> Void)?
    var onResumed: (() -> Void)?
    var onPlaybackTime: ((TimeInterval) -> Void)?

    init() {}

    var isAvailable: Bool { VLCEnvironment.shared.instance != nil }

    func attach(_ view: NSView) {
        self.view = view
        if let player { libvlc_media_player_set_nsobject(player, Unmanaged.passUnretained(view).toOpaque()) }
    }

    func detach(_ view: NSView) {
        guard self.view === view else { return }
        stop()
        if let player { libvlc_media_player_set_nsobject(player, nil) }
        self.view = nil
    }

    @discardableResult func play(_ url: URL, recoverRecording: Bool = false) -> Bool {
        monitor?.invalidate()
        monitor = nil
        recordingURL = recoverRecording ? url : nil
        elapsedOffset = 0
        lastTime = -1
        lastPictures = -1
        hasProgress = false
        lastProgress = Date()
        segmentStarted = Date()
        lastRetry = .distantPast
        retries = 0
        recovering = false
        let started = start(url)
        if started && recoverRecording {
            monitor = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkPlayback() }
            }
        }
        return started
    }

    private func start(_ url: URL) -> Bool {
        guard let instance = VLCEnvironment.shared.instance,
              let next = libvlc_media_player_new(instance) else { return false }
        guard let media = libvlc_media_new_location(instance, url.absoluteString) else {
            libvlc_media_player_release(next)
            return false
        }
        libvlc_media_add_option(media, ":rtsp-tcp")
        libvlc_media_add_option(media, ":network-caching=1200")
        if let view { libvlc_media_player_set_nsobject(next, Unmanaged.passUnretained(view).toOpaque()) }
        libvlc_media_player_set_media(next, media)
        libvlc_media_release(media)
        let previous = player
        player = next
        if let previous { VLCReaper.retire(previous) }
        return libvlc_media_player_play(next) == 0
    }

    private func checkPlayback() {
        guard let player, let original = recordingURL else { return }
        let now = Date()
        let currentTime = libvlc_media_player_get_time(player)
        var stats = libvlc_media_stats_t()
        let media = libvlc_media_player_get_media(player)
        let hasStats = media.map { libvlc_media_get_stats($0, &stats) != 0 } ?? false
        if let media { libvlc_media_release(media) }
        let pictures = hasStats ? stats.i_displayed_pictures : -1
        let advanced = pictures > 0 ? pictures > lastPictures : currentTime > 0 && currentTime > lastTime
        if advanced {
            if !hasProgress { segmentStarted = now }
            lastProgress = now
            hasProgress = true
            retries = 0
            if recovering {
                recovering = false
                onResumed?()
            }
        }
        if currentTime >= 0 { lastTime = currentTime }
        if pictures >= 0 { lastPictures = pictures }
        let state = libvlc_media_player_get_state(player)
        let stale = now.timeIntervalSince(lastProgress) > (hasProgress ? 8 : 20)
        let segmentElapsed = lastTime > 0 ? Double(lastTime) / 1000 : (hasProgress ? now.timeIntervalSince(segmentStarted) : 0)
        if advanced { onPlaybackTime?(elapsedOffset + segmentElapsed) }
        guard state != libvlc_Ended || RecordingPlayback.resume(original, elapsedSeconds: max(1, elapsedOffset + segmentElapsed)) != nil else {
            monitor?.invalidate(); monitor = nil
            return
        }
        guard stale || state == libvlc_Error || state == libvlc_Stopped || state == libvlc_Ended else { return }
        let delay = min(30.0, pow(2.0, Double(min(retries, 5))))
        guard now.timeIntervalSince(lastRetry) >= delay else { return }
        elapsedOffset += segmentElapsed
        let nextURL = RecordingPlayback.resume(original, elapsedSeconds: elapsedOffset) ?? original
        retries += 1
        lastRetry = now
        lastProgress = now
        segmentStarted = now
        lastTime = -1
        lastPictures = -1
        hasProgress = false
        recovering = true
        onRecovery?(retries)
        _ = start(nextURL)
    }

    func stop() {
        monitor?.invalidate()
        monitor = nil
        recordingURL = nil
        onRecovery = nil
        onResumed = nil
        onPlaybackTime = nil
        recovering = false
        if let player {
            self.player = nil
            VLCReaper.retire(player)
        }
    }

    deinit {
        if let player { VLCReaper.retire(player) }
    }
}

struct VLCVideoView: NSViewRepresentable {
    let player: VLCPlayer

    final class Coordinator {
        let player: VLCPlayer
        init(player: VLCPlayer) { self.player = player }
    }

    func makeCoordinator() -> Coordinator { Coordinator(player: player) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        player.attach(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.player.detach(nsView)
    }
}
