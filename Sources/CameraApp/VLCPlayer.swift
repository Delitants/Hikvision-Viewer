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
    private var recovery: PlaybackRecovery?
    private var streams: PlaybackStreamSelection?
    private var liveStreams: LiveStreamSelection?
    @Published private(set) var isActive = false
    @Published private(set) var isPaused = false
    @Published private(set) var isBuffering = false
    @Published private(set) var streamQuality: StreamQuality = .main
    var onRecovery: ((Int) -> Void)?
    var onResumed: (() -> Void)?
    var onPlaybackTime: ((TimeInterval) -> Void)?
    var onCompleted: (() -> Void)?
    var onFailure: (() -> Void)?
    var onStreamQuality: ((StreamQuality) -> Void)?

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
        streams = recoverRecording ? PlaybackStreamSelection(main: url) : nil
        liveStreams = nil
        streamQuality = .main
        if !recoverRecording {
            onPlaybackTime = nil; onRecovery = nil; onResumed = nil; onCompleted = nil; onFailure = nil; onStreamQuality = nil
        }
        recovery = recoverRecording ? PlaybackRecovery(now: ProcessInfo.processInfo.systemUptime,
                                                       duration: RecordingPlayback.duration(url)) : nil
        isPaused = false
        let started = start(url, cacheMilliseconds: 3000)
        isActive = started
        isBuffering = started
        if started {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkPlayback() }
            }
            monitor = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        return started
    }

    @discardableResult func playLive(main: URL, sub: URL?) -> Bool {
        var selection = LiveStreamSelection(main: main, sub: sub)
        var started = play(selection.url)
        if !started && sub != nil {
            _ = selection.retry(attempt: 1)
            started = play(selection.url)
        }
        guard started else { stop(); return false }
        liveStreams = selection
        streamQuality = selection.quality
        recovery = PlaybackRecovery(now: ProcessInfo.processInfo.systemUptime, duration: nil,
                                    finishOnEnded: false, startupGrace: 12)
        return true
    }

    private func start(_ url: URL, cacheMilliseconds: Int) -> Bool {
        guard let instance = VLCEnvironment.shared.instance,
              let next = libvlc_media_player_new(instance) else { return false }
        guard let media = libvlc_media_new_location(instance, url.absoluteString) else {
            libvlc_media_player_release(next)
            return false
        }
        libvlc_media_add_option(media, ":rtsp-tcp")
        libvlc_media_add_option(media, ":network-caching=\(cacheMilliseconds)")
        libvlc_media_player_set_media(next, media)
        libvlc_media_release(media)
        let previous = player
        if let previous { libvlc_media_player_set_nsobject(previous, nil) }
        player = next
        if let view { libvlc_media_player_set_nsobject(next, Unmanaged.passUnretained(view).toOpaque()) }
        if let previous { VLCReaper.retire(previous) }
        return libvlc_media_player_play(next) == 0
    }

    private func checkPlayback() {
        guard let player else { return }
        if var liveStreams, var recovery {
            let currentTime = libvlc_media_player_get_time(player)
            var stats = libvlc_media_stats_t()
            let media = libvlc_media_player_get_media(player)
            let hasStats = media.map { libvlc_media_get_stats($0, &stats) != 0 } ?? false
            if let media { libvlc_media_release(media) }
            let state: PlaybackEngineState
            switch libvlc_media_player_get_state(player) {
            case libvlc_Playing: state = .playing
            case libvlc_Paused: state = .paused
            case libvlc_Stopped: state = .stopped
            case libvlc_Ended: state = .ended
            case libvlc_Error: state = .failed
            case libvlc_Buffering: state = .buffering
            default: state = .opening
            }
            let update = recovery.observe(now: ProcessInfo.processInfo.systemUptime,
                                          mediaTime: max(0, Double(currentTime) / 1000),
                                          pictures: hasStats ? Int(stats.i_displayed_pictures) : nil,
                                          state: state)
            self.recovery = recovery
            if update.progress != nil {
                liveStreams.displayedFrame()
                isBuffering = false
            }
            switch update.action {
            case .none:
                if state == .buffering || state == .opening { isBuffering = true }
            case let .retry(_, attempt, cache):
                let nextURL = liveStreams.retry(attempt: attempt)
                if streamQuality != liveStreams.quality {
                    streamQuality = liveStreams.quality
                    onStreamQuality?(streamQuality)
                }
                isBuffering = true
                _ = start(nextURL, cacheMilliseconds: cache)
            case .finished: break
            }
            self.liveStreams = liveStreams
            return
        }
        guard let original = recordingURL, var recovery else {
            let state = libvlc_media_player_get_state(player)
            isBuffering = !isPaused && (state == libvlc_Opening || state == libvlc_Buffering)
            if state == libvlc_Ended || state == libvlc_Error { stop() }
            return
        }
        let currentTime = libvlc_media_player_get_time(player)
        var stats = libvlc_media_stats_t()
        let media = libvlc_media_player_get_media(player)
        let hasStats = media.map { libvlc_media_get_stats($0, &stats) != 0 } ?? false
        if let media { libvlc_media_release(media) }
        let engineState: PlaybackEngineState
        switch libvlc_media_player_get_state(player) {
        case libvlc_Playing: engineState = .playing
        case libvlc_Paused: engineState = .paused
        case libvlc_Stopped: engineState = .stopped
        case libvlc_Ended: engineState = .ended
        case libvlc_Error: engineState = .failed
        case libvlc_Buffering: engineState = .buffering
        default: engineState = .opening
        }
        let update = recovery.observe(now: ProcessInfo.processInfo.systemUptime,
                                      mediaTime: max(0, Double(currentTime) / 1000),
                                      pictures: hasStats ? Int(stats.i_displayed_pictures) : nil,
                                      state: isPaused ? .paused : engineState)
        self.recovery = recovery
        if let progress = update.progress {
            streams?.displayedFrame()
            isBuffering = false
            onPlaybackTime?(progress)
        }
        if update.resumed { onResumed?() }
        switch update.action {
        case .none:
            if engineState == .buffering || engineState == .opening { isBuffering = !isPaused }
        case let .retry(elapsed, attempt, cache):
            if engineState == .ended && streamQuality == .sub { streams?.rejectSubstream() }
            let nextURL: URL?
            if var selection = streams {
                nextURL = selection.retry(elapsed: elapsed, attempt: attempt)
                streams = selection
                if streamQuality != selection.quality {
                    streamQuality = selection.quality
                    onStreamQuality?(streamQuality)
                }
            } else { nextURL = elapsed == 0 ? original : RecordingPlayback.resume(original, elapsedSeconds: elapsed) }
            guard let nextURL else {
                let failure = onFailure
                stop()
                failure?()
                return
            }
            isBuffering = true
            onRecovery?(attempt)
            _ = start(nextURL, cacheMilliseconds: cache)
        case .finished:
            let completion = onCompleted
            stop()
            completion?()
        }
    }

    func togglePause() {
        guard let player, isActive else { return }
        isPaused.toggle()
        libvlc_media_player_set_pause(player, isPaused ? 1 : 0)
    }

    func setRecordedSubstream(_ url: URL) {
        streams?.setRecordedSubstream(url)
    }

    func stop() {
        monitor?.invalidate()
        monitor = nil
        recordingURL = nil
        recovery = nil
        streams = nil
        liveStreams = nil
        isActive = false
        isPaused = false
        isBuffering = false
        onRecovery = nil
        onResumed = nil
        onPlaybackTime = nil
        onCompleted = nil
        onFailure = nil
        onStreamQuality = nil
        if let player {
            self.player = nil
            libvlc_media_player_set_nsobject(player, nil)
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
