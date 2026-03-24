import SwiftUI

struct MenuBarView: View {
    @ObservedObject var engine: AudioEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("Retune")
                    .font(.headline)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { engine.isRunning },
                    set: { newValue in
                        if newValue { engine.start() } else { engine.stop() }
                    }
                ))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            Divider()

            // Reference note selector
            HStack(spacing: 8) {
                Text("Reference")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Picker("", selection: $engine.referenceNote) {
                    ForEach(ReferenceNote.allCases, id: \.self) { note in
                        Text(note.rawValue).tag(note)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 80)
            }

            // Target pitch
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(engine.referenceLabel) =")
                        .font(.system(.body, design: .monospaced))
                    Text("\(Int(engine.referenceFreq)) Hz")
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.semibold)
                    Spacer()
                    Text(String(format: "%+.1f¢", engine.centsValue))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Slider(value: $engine.referenceFreq,
                       in: engine.referenceRange, step: 1)
                HStack {
                    Text("\(Int(engine.referenceRange.lowerBound))")
                        .font(.caption2).foregroundColor(.secondary)
                    Spacer()
                    ForEach(engine.referencePresets, id: \.1) { label, value in
                        Button(label) { engine.referenceFreq = value }
                            .buttonStyle(.plain)
                            .font(.caption2)
                            .foregroundColor(.accentColor)
                        if value != engine.referencePresets.last?.1 {
                            Spacer()
                        }
                    }
                    Spacer()
                    Text("\(Int(engine.referenceRange.upperBound))")
                        .font(.caption2).foregroundColor(.secondary)
                }
                if engine.referenceNote == .C {
                    Text(String(format: "(A4 = %.1f Hz)", engine.targetA))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            // Buffer size
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Buffer")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(engine.bufferSize) frames · \(engine.bufferLatencyMs)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Slider(
                    value: Binding(
                        get: {
                            Double(AudioEngine.bufferSizes.firstIndex(of: engine.bufferSize) ?? 3)
                        },
                        set: { newVal in
                            let idx = Int(newVal.rounded())
                            let clamped = min(max(idx, 0), AudioEngine.bufferSizes.count - 1)
                            engine.bufferSize = AudioEngine.bufferSizes[clamped]
                        }
                    ),
                    in: 0...Double(AudioEngine.bufferSizes.count - 1),
                    step: 1
                )
                HStack {
                    Text("64")
                        .font(.caption2).foregroundColor(.secondary)
                    Spacer()
                    Text("← latency    quality →")
                        .font(.caption2).foregroundColor(.secondary).opacity(0.5)
                    Spacer()
                    Text("16384")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }

            Divider()

            // Status
            if engine.isRunning {
                HStack {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                    Text("Active")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    if let sr = engine.currentSampleRate {
                        Text("\(Int(sr)) Hz")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Text("System audio tap → pitch shift → output")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .opacity(0.7)
            } else {
                HStack {
                    Circle()
                        .fill(.gray)
                        .frame(width: 6, height: 6)
                    Text("Stopped")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            Button("Quit") {
                engine.stop()
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding()
        .frame(width: 260)
    }
}
