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

    @discardableResult func play(_ url: URL) -> Bool {
        guard let instance = VLCEnvironment.shared.instance,
              let next = libvlc_media_player_new(instance) else { return false }
        guard let media = libvlc_media_new_location(instance, url.absoluteString) else {
            libvlc_media_player_release(next)
            return false
        }
        libvlc_media_add_option(media, ":rtsp-tcp")
        libvlc_media_add_option(media, ":network-caching=300")
        if let view { libvlc_media_player_set_nsobject(next, Unmanaged.passUnretained(view).toOpaque()) }
        libvlc_media_player_set_media(next, media)
        libvlc_media_release(media)
        let previous = player
        player = next
        if let previous { VLCReaper.retire(previous) }
        return libvlc_media_player_play(next) == 0
    }

    func stop() {
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
