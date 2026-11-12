import AppKit
import SwiftUI

struct RecordingPlaybackControls: View {
    @ObservedObject var player: VLCPlayer
    let hasRecordings: Bool
    let onPlayPause: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if player.isActive && player.streamQuality == .sub { Text("Substream").font(.caption).foregroundStyle(.secondary) }
            if player.isBuffering { ProgressView().controlSize(.small); Text("Buffering…").font(.caption) }
            Button(player.isActive && !player.isPaused ? "Pause" : "Play",
                   systemImage: player.isActive && !player.isPaused ? "pause.fill" : "play.fill", action: onPlayPause)
                .disabled(!hasRecordings && !player.isActive)
            Button("Stop", systemImage: "stop.fill", action: onStop).disabled(!player.isActive)
        }
    }
}

struct RecordingTimelineView: View {
    let start: Date
    let end: Date
    let recordings: [Recording]
    @Binding var selectedTime: Date
    let onSeek: (Date) -> Void
    @State private var span: TimeInterval = 86400
    @State private var showingPosition = false
    @State private var positionDate = Date()
    @State private var positionClock = "00:00:00"

    private var position: Date? {
        let values = positionClock.split(separator: ":").compactMap { Int($0) }
        guard values.count == 3, (0...23).contains(values[0]), (0...59).contains(values[1]), (0...59).contains(values[2]),
              let time = Calendar.current.date(bySettingHour: values[0], minute: values[1], second: values[2], of: positionDate),
              time >= start, time < end else { return nil }
        return time
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Recorded video", systemImage: "rectangle.fill").font(.caption).foregroundStyle(.white.opacity(0.8))
                if recordings.contains(where: { $0.kind == .event }) {
                    Label("Event", systemImage: "rectangle.fill").font(.caption).foregroundStyle(.orange)
                }
                Spacer(minLength: 8)
                Button { span = min(7 * 86400, span * 2) } label: { Image(systemName: "minus.magnifyingglass").frame(width: 30, height: 28) }
                    .foregroundStyle(.white.opacity(0.9))
                    .disabled(span >= 7 * 86400).help("Zoom out timeline").accessibilityLabel("Zoom out timeline")
                Button { span = max(300, span / 2) } label: { Image(systemName: "plus.magnifyingglass").frame(width: 30, height: 28) }
                    .foregroundStyle(.white.opacity(0.9))
                    .disabled(span <= 300).help("Zoom in timeline").accessibilityLabel("Zoom in timeline")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10).padding(.top, 6)
            .overlay(alignment: .center) {
                Button {
                    positionDate = selectedTime
                    let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"
                    positionClock = formatter.string(from: selectedTime)
                    showingPosition = true
                } label: {
                    Text(selectedTime.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute().second()))
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color(red: 0.65, green: 0.08, blue: 0.12), in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain).accessibilityLabel("Go to playback time")
                .popover(isPresented: $showingPosition) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Go to time").font(.headline)
                        DatePicker("Date", selection: $positionDate, in: start...end.addingTimeInterval(-1), displayedComponents: .date)
                        TextField("Time (HH:mm:ss)", text: $positionClock).textFieldStyle(.roundedBorder)
                        HStack {
                            Spacer()
                            Button("Go") { if let position { selectedTime = position; onSeek(position); showingPosition = false } }
                                .disabled(position == nil || recordings.isEmpty).keyboardShortcut(.defaultAction)
                        }
                    }.padding(18).frame(width: 280)
                        .background(Color(nsColor: .windowBackgroundColor))
                }
            }
            TimelineRuler(start: start, end: end, recordings: recordings, selectedTime: $selectedTime, span: $span, onSeek: onSeek)
                .frame(height: 94)
        }
        .background(Color(white: 0.055))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private struct TimelineRuler: NSViewRepresentable {
    let start: Date
    let end: Date
    let recordings: [Recording]
    @Binding var selectedTime: Date
    @Binding var span: TimeInterval
    let onSeek: (Date) -> Void

    func makeNSView(context: Context) -> TimelineRulerView { TimelineRulerView() }
    func updateNSView(_ view: TimelineRulerView, context: Context) {
        view.start = start; view.end = end; view.recordings = recordings; view.span = span
        if !view.isScrubbing { view.selectedTime = selectedTime }
        view.onPreview = { selectedTime = $0 }
        view.onSeek = onSeek
        view.onZoom = { span = max(300, min(7 * 86400, $0)) }
        view.needsDisplay = true
    }
}

private final class TimelineRulerView: NSView {
    var start = Date(), end = Date().addingTimeInterval(86400), selectedTime = Date()
    var recordings: [Recording] = []
    var span: TimeInterval = 86400
    var onPreview: ((Date) -> Void)?
    var onSeek: ((Date) -> Void)?
    var onZoom: ((TimeInterval) -> Void)?
    var isScrubbing = false
    private var dragOrigin = NSPoint.zero
    private var dragTime = Date()
    private var wheelSeek: Timer?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var viewport: TimelineViewport { TimelineViewport(start: start, end: end, center: selectedTime, span: span) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.055, alpha: 1).setFill(); bounds.fill()
        let width = bounds.width
        guard width > 0 else { return }
        let scale = viewport
        NSColor(white: 0.14, alpha: 1).setFill(); NSRect(x: 0, y: 40, width: width, height: 38).fill()
        for recording in recordings {
            let left = max(0, scale.fraction(for: max(start, recording.start)) * width)
            let right = min(width, scale.fraction(for: min(end, recording.end)) * width)
            guard right > left else { continue }
            let color: NSColor
            switch recording.kind {
            case .continuous: color = NSColor(red: 0.12, green: 0.46, blue: 0.83, alpha: 1)
            case .event: color = .systemOrange
            case .manual: color = .systemGreen
            case .unknown: color = NSColor(white: 0.45, alpha: 1)
            }
            color.setFill(); NSRect(x: left, y: 48, width: right - left, height: 22).fill()
        }
        let step = scale.tickInterval(width: width)
        let origin = Calendar.current.startOfDay(for: scale.center)
        let lower = scale.center.addingTimeInterval(-scale.span / 2)
        var tick = origin.addingTimeInterval(floor(lower.timeIntervalSince(origin) / step) * step)
        let format = DateFormatter(); format.dateFormat = step >= 86400 ? "MMM d" : (step < 60 ? "HH:mm:ss" : "HH:mm")
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor(white: 0.7, alpha: 1)]
        while tick <= scale.center.addingTimeInterval(scale.span / 2) {
            let x = scale.fraction(for: tick) * width
            if x >= 0 && x <= width {
                NSColor(white: 0.5, alpha: 1).setFill(); NSRect(x: x, y: 28, width: 1, height: 10).fill()
                let label = format.string(from: tick) as NSString
                let size = label.size(withAttributes: attributes)
                label.draw(at: NSPoint(x: min(max(2, x - size.width / 2), width - size.width - 2), y: 10), withAttributes: attributes)
                for minor in 1..<4 {
                    let minorX = x + Double(minor) * step / 4 / scale.span * width
                    NSColor(white: 0.25, alpha: 1).setFill(); NSRect(x: minorX, y: 33, width: 1, height: 5).fill()
                }
            }
            tick = tick.addingTimeInterval(step)
        }
        NSColor.systemRed.setFill(); NSRect(x: width / 2 - 1, y: 0, width: 2, height: 84).fill()
        let triangle = NSBezierPath(); triangle.move(to: NSPoint(x: width / 2 - 5, y: 0)); triangle.line(to: NSPoint(x: width / 2 + 5, y: 0)); triangle.line(to: NSPoint(x: width / 2, y: 7)); triangle.close(); triangle.fill()
        if recordings.isEmpty {
            ("Search to show recorded periods" as NSString).draw(at: NSPoint(x: 12, y: 51), withAttributes: attributes)
        }
    }

    private func preview(_ time: Date) {
        selectedTime = min(max(time, start), end.addingTimeInterval(-1))
        onPreview?(selectedTime); needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragOrigin = convert(event.locationInWindow, from: nil); dragTime = selectedTime; isScrubbing = true
    }
    override func mouseDragged(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        preview(dragTime.addingTimeInterval(-(x - dragOrigin.x) / max(1, bounds.width) * span))
    }
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if abs(point.x - dragOrigin.x) < 3 { preview(viewport.time(at: point.x / max(1, bounds.width))) }
        isScrubbing = false
        if !recordings.isEmpty { onSeek?(selectedTime) }
    }
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            isScrubbing = true
            preview(selectedTime.addingTimeInterval(-event.scrollingDeltaX / max(1, bounds.width) * span))
            wheelSeek?.invalidate()
            let timer = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.isScrubbing = false
                if !self.recordings.isEmpty { self.onSeek?(self.selectedTime) }
            }
            wheelSeek = timer; RunLoop.main.add(timer, forMode: .common)
        } else { onZoom?(span * (event.scrollingDeltaY > 0 ? 0.8 : 1.25)) }
    }
    override func keyDown(with event: NSEvent) {
        let step: TimeInterval = event.modifierFlags.contains(.shift) ? 60 : 1
        switch event.keyCode {
        case 123: preview(selectedTime.addingTimeInterval(-step)); if !recordings.isEmpty { onSeek?(selectedTime) }
        case 124: preview(selectedTime.addingTimeInterval(step)); if !recordings.isEmpty { onSeek?(selectedTime) }
        default: super.keyDown(with: event)
        }
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityLabel() -> String? { "Recording timeline" }
    override func accessibilityValue() -> Any? { selectedTime.timeIntervalSince(start) }
    override func accessibilityMinValue() -> Any? { 0 }
    override func accessibilityMaxValue() -> Any? { max(0, end.timeIntervalSince(start) - 1) }
    override func accessibilityValueDescription() -> String? { selectedTime.formatted(date: .abbreviated, time: .standard) }
    override func setAccessibilityValue(_ value: Any?) {
        guard let value = value as? NSNumber else { return }
        preview(start.addingTimeInterval(value.doubleValue)); if !recordings.isEmpty { onSeek?(selectedTime) }
    }
    override func accessibilityPerformIncrement() -> Bool { preview(selectedTime.addingTimeInterval(60)); if !recordings.isEmpty { onSeek?(selectedTime) }; return true }
    override func accessibilityPerformDecrement() -> Bool { preview(selectedTime.addingTimeInterval(-60)); if !recordings.isEmpty { onSeek?(selectedTime) }; return true }
    deinit { wheelSeek?.invalidate() }
}
