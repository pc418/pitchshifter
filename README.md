# PitchShift

<p align="center">
  <img src="assets/Gemini_Generated_Image_bg2bt1bg2bt1bg2b.png" width="128" alt="PitchShift icon">
</p>

A macOS menu bar app that pitch-shifts all system audio in real time.

Modern concert pitch (A4 = 440 Hz) was standardized in 1955 by the ISO. But for most of Western music history, pitch was lower — Baroque ensembles tuned to A = 415 Hz, and even into the Classical era, A hovered around 420–430 Hz. The push toward 440 and above is a relatively recent phenomenon, driven largely by orchestral "brightness wars": higher tuning makes instruments sound more brilliant and exciting in a concert hall, which audiences respond to, which pushes ensembles to tune even higher. Many European orchestras now tune to A = 443 Hz or above.

The result is that virtually all recorded and streamed music today is tuned to 440 Hz or higher — a standard chosen for projection and excitement, not necessarily for comfort or consonance. Some listeners find that lower tuning standards (432 Hz, 256 Hz for C4) produce a warmer, more relaxed quality. Whether you prefer Verdi's A = 432, scientific C = 256, or historical Baroque pitch, PitchShift lets you retune everything playing on your Mac to hear it the way you want.

## Requirements

- macOS 14.2+ (uses Core Audio Tap API)
- Xcode Command Line Tools

## Build

```bash
git clone https://github.com/pc418/pitchshifter.git
cd pitchshifter
make build     # release build, package .app, ad-hoc codesign
make run       # build + open
make install   # copy to /Applications
make clean     # remove build artifacts
```

## Usage

PitchShift lives in the menu bar. The icon shows **♮** when active and **#** when disabled.

Open the panel to toggle pitch shifting and set your preferred tuning:

**Reference modes:**
- **A mode** — Set A4 directly (range: 415–460 Hz, default 432 Hz)
- **C mode** — Set C4 directly (range: 240–270 Hz, default 256 Hz)

**Built-in presets:**
- A4 = 415 Hz — Baroque pitch
- A4 = 432 Hz — Verdi tuning
- A4 = 440 Hz — ISO standard (no shift)
- A4 = 443 Hz — European orchestral pitch
- C4 = 256 Hz — Scientific / Schiller pitch (A4 ≈ 430.5 Hz)

Your chosen frequency persists across restarts. When disabled, the display resets to A = 440 Hz; your preference is remembered and restored when you re-enable.

The app automatically follows your system default audio output device — plug in headphones, connect Bluetooth, switch outputs, and PitchShift adapts without interruption.

## How it works

```
Core Audio Tap → IOProc → RingBuffer → AVAudioSourceNode → AVAudioUnitTimePitch → Output
```

1. **System audio capture** — `CATapDescription` creates a stereo global tap that captures all system audio except the app's own output, avoiding feedback loops.
2. **Aggregate device** — An aggregate device pairs the tap with the physical output, providing a single IOProc-based capture path.
3. **Ring buffer** — A lock-free dual-channel ring buffer (non-interleaved, power-of-2 capacity, Accelerate-backed) bridges the IOProc real-time thread to the AVAudioEngine pull model.
4. **Pitch shifting** — `AVAudioUnitTimePitch` applies the frequency shift at maximum render quality (overlap = 32, quality = 127), preserving tempo while changing pitch.
5. **Output** — The processed audio routes to your selected physical device.

No virtual audio drivers, kernel extensions, or microphone access required. The tap reads system audio output directly via the Core Audio Tap API introduced in macOS 14.2.

## Advanced

The panel includes an Advanced section for buffer size control:
- **Auto mode** selects a buffer that gives ≥ 20 ms latency at the current sample rate
- **Manual mode** lets you pick from 16 to 16384 frames — lower = less latency, higher = better quality
- Per-sample-rate buffer sizes are remembered independently

## License

[Apache License 2.0](LICENSE)
