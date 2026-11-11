import SwiftUI

struct RecordingTimelineView: View {
    let start: Date
    let end: Date
    let recordings: [Recording]
    @Binding var selectedTime: Date
    let onSeek: (Date) -> Void

    private var duration: TimeInterval { max(1, end.timeIntervalSince(start)) }

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text("Timeline").font(.headline)
                Spacer()
                Text(selectedTime.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline.monospacedDigit())
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gray.opacity(0.25))
                    ForEach(recordings, id: \.self) { recording in
                        let lower = max(0, recording.start.timeIntervalSince(start) / duration)
                        let upper = min(1, recording.end.timeIntervalSince(start) / duration)
                        if upper > lower {
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: max(2, (upper - lower) * geometry.size.width))
                                .offset(x: lower * geometry.size.width)
                        }
                    }
                }
            }
            .frame(height: 8)
            .accessibilityLabel("Recorded periods")
            Slider(value: Binding(
                get: { min(duration, max(0, selectedTime.timeIntervalSince(start))) },
                set: { selectedTime = start.addingTimeInterval($0) }
            ), in: 0...duration, onEditingChanged: { editing in
                if !editing { onSeek(selectedTime) }
            })
            .disabled(recordings.isEmpty)
            .accessibilityLabel("Recording timeline")
            HStack {
                Text(start.formatted(date: .abbreviated, time: .shortened))
                Spacer()
                Text(end.addingTimeInterval(-1).formatted(date: .abbreviated, time: .shortened))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
