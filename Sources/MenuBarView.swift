import SwiftUI

struct MenuBarView: View {
    @ObservedObject var engine: AudioEngine
    @State private var advancedExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("PitchShift")
                    .font(.headline)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { engine.isRunning || engine.isRestarting },
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

            Divider()

            // Status
            if engine.isRunning || engine.isRestarting {
                HStack {
                    Circle()
                        .fill(engine.isRestarting ? .orange : .green)
                        .frame(width: 6, height: 6)
                    Text(engine.isRestarting ? "Restarting…" : "Active")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    if let sr = engine.currentSampleRate {
                        Text("\(Int(sr)) Hz")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
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

            // Advanced section
            DisclosureGroup(isExpanded: $advancedExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    // Buffer size
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Buffer")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Toggle("Auto", isOn: Binding(
                                get: { engine.isAutoBuffer },
                                set: { newValue in
                                    if newValue {
                                        engine.enableAutoBuffer()
                                    } else {
                                        engine.isAutoBuffer = false
                                    }
                                }
                            ))
                            .toggleStyle(.checkbox)
                            .font(.caption)
                        }
                        HStack {
                            Spacer()
                            Text("\(engine.bufferSize) frames · \(engine.bufferLatencyLabel)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: {
                                    Double(AudioEngine.bufferSizes.firstIndex(of: engine.bufferSize) ?? 5)
                                },
                                set: { newVal in
                                    let idx = Int(newVal.rounded())
                                    let clamped = min(max(idx, 0), AudioEngine.bufferSizes.count - 1)
                                    engine.setManualBuffer(AudioEngine.bufferSizes[clamped])
                                }
                            ),
                            in: 0...Double(AudioEngine.bufferSizes.count - 1),
                            step: 1
                        )
                        .disabled(engine.isAutoBuffer)
                        HStack {
                            Text("16")
                                .font(.caption2).foregroundColor(.secondary)
                            Spacer()
                            Text("← latency    quality →")
                                .font(.caption2).foregroundColor(.secondary).opacity(0.5)
                            Spacer()
                            Text("16384")
                                .font(.caption2).foregroundColor(.secondary)
                        }

                        // Low latency warning
                        if engine.bufferLatencyMs < 5.0 {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                                Text("Very low latency — audio quality may be impacted")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                            }
                        }
                    }

                    Divider()

                    // Example pitch values
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Example shifts")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Group {
                            Text("A4 = 432 Hz → −31.8¢ (Verdi tuning)")
                            Text("A4 = 415 Hz → −102.0¢ (Baroque pitch)")
                            Text("A4 = 443 Hz → +11.8¢ (European bright)")
                            Text("C4 = 256 Hz → A4 ≈ 430.5 (Scientific)")
                        }
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                        .opacity(0.7)
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("Advanced")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            HStack {
                Text("v1.4.3")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .opacity(0.5)
                Spacer()
                Button("Quit") {
                    engine.stop()
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .padding()
        .frame(width: 280)
    }
}
