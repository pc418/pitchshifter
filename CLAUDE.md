# PitchShift — Development Guide

## What this is

macOS menu bar app that pitch-shifts all system audio in real time. Written in Swift, uses Core Audio Tap API (macOS 14.2+), no virtual audio drivers.

## Build

```bash
make build             # release build, packages .app, ad-hoc codesigns
make run               # build + open
make install           # copy to /Applications
make clean             # remove build artifacts
```

## Sign, Notarize & Release

```bash
bash sign.sh                                                          # Developer ID codesign
ditto -c -k --keepParent pitchshift.app pitchshift.zip                # zip for notarization
xcrun notarytool submit pitchshift.zip --keychain-profile "pc418" --wait   # notarize
xcrun stapler staple pitchshift.app                                   # staple ticket
rm pitchshift.zip && ditto -c -k --keepParent pitchshift.app pitchshift.zip  # re-zip with staple
gh release create vX.Y.Z pitchshift.zip --title "vX.Y.Z" --notes "..."     # GitHub release
```

Keychain profile `pc418` stores Apple notarization credentials (team VBC54DC2R5).

Requires Xcode Command Line Tools.

## Architecture

```
IOProc (Core Audio)  →  RingBuffer  →  AVAudioSourceNode  →  AVAudioUnitTimePitch  →  Output
     (aggregate device)     (dual-channel,     (reads non-        (pitch shift          (physical
      captures tap)          lock-free)         interleaved)       at max quality)        device)
```

### Key files

- **AudioEngine.swift** — Core audio pipeline: tap creation, aggregate device, IOProc capture, AVAudioEngine setup, device change handling, sleep/wake recovery, UserDefaults persistence
- **RingBuffer.swift** — Dual-channel (non-interleaved) ring buffer with power-of-2 bitmask, memcpy bulk ops, Accelerate (vDSP_vclr) for silence fill
- **AudioDeviceManager.swift** — CoreAudio device enumeration, property queries
- **MenuBarView.swift** — SwiftUI UI: reference picker, frequency slider, status
- **PitchShiftApp.swift** — App entry point, single-instance guard, MenuBarExtra
- **PitchShiftLogger.swift** — File logger to ~/Library/Logs/pitchshift.log

### Audio pipeline details

1. `CATapDescription(stereoGlobalTapButExcludeProcesses:)` — captures all system audio except self
2. `AudioHardwareCreateAggregateDevice` — aggregate with tap list + output sub-device
3. IOProc on aggregate device reads input buffers (tap audio) into RingBuffer
4. AVAudioSourceNode pulls from RingBuffer into AVAudioEngine graph
5. AVAudioUnitTimePitch applies pitch shift (overlap=32, render quality=127/max)
6. Output node routes to selected physical device

### Ring buffer design

Dual-channel (separate L/R buffers), not interleaved. This avoids interleave/deinterleave on every read/write cycle. Uses `os_unfair_lock`, `memcpy` for bulk channel operations, `vDSP_vclr` for vectorized silence fill. Capacity is always power-of-2 for bitmask indexing.

### Device handling

- Always follows system default output device
- Listens for `kAudioHardwarePropertyDefaultOutputDevice` changes (headphone plug, Bluetooth connect)
- Listens for `kAudioHardwarePropertyDevices` changes (devices added/removed)
- Listens for `kAudioDevicePropertyNominalSampleRate` changes on the output device
- Clean teardown before sleep via `NSWorkspace.willSleepNotification`
- Auto-restart after wake via `NSWorkspace.didWakeNotification` (2s delay) — only if engine was running pre-sleep
- Tracks screen sleep/wake via `screensDidSleepNotification` / `screensDidWakeNotification` for diagnostics
- User-initiated stop clears pre-sleep state so wake doesn't auto-restart

## Settings persistence

Stored in UserDefaults:
- `referenceNote` — "C" or "A"
- `referenceFreq` — Float (e.g. 256, 432)
- `bufferSize` — Int (IO buffer frame count, e.g. 512)
- `autoBuffer` — Bool (auto buffer sizing enabled)
- `bufferSizePerRate` — [String: Int] (per-sample-rate manual buffer sizes)

## Entitlements

- `com.apple.security.app-sandbox = false` — required for Core Audio Tap API access

No microphone entitlement needed. The tap reads system audio output, not input.

## Conventions

- All log lines prefixed with `[PitchShift]`
- Log file: `~/Library/Logs/pitchshift.log`
- Single instance enforced via flock on `/tmp/pitchshift.lock`
- App uses `.accessory` activation policy (menu bar only, no dock icon)

## Common tasks

**Change pitch algorithm quality**: In AudioEngine.swift `setupAVEngine()`, the `kAudioUnitProperty_RenderQuality` is set to 127 (max). Lower values trade quality for CPU.

**Change IO buffer size**: In `createAggregateDevice()`, `kAudioDevicePropertyBufferFrameSize` is set from the `bufferSize` property (default auto ≥ 20 ms). Configurable in the Advanced UI panel. Smaller = lower latency but higher CPU.

**Add a new reference preset**: In AudioEngine.swift, add to `referencePresets` array.

## Version bumping
./Sources/MenuBarView.swift also has a version text to bump, either link that to actual version then del this msg or bump everytime.