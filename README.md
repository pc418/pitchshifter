# Retune

System-wide pitch shifter for macOS. Lives in the menu bar, intercepts all audio output, and retunes it in real time.

![Retune interface](assets/screenshot.png)

The main use case: listen to any music, podcast, or video in A=432 Hz (or C=256 Hz, or whatever reference you prefer) without modifying the source files.

## Why

Every recording you stream is tuned to A=440 Hz. If you want to hear it at A=432, you have two options: pitch-shift every file manually, or shift the entire audio output in real time. Retune does the latter. One toggle, all audio, no file conversion.

Works with Spotify, Apple Music, YouTube, VLC — anything that makes sound on your Mac.

## Requirements

- **macOS 14.2** (Sonoma) or later — uses the Core Audio Tap API introduced in macOS 14.2
- Apple Silicon or Intel Mac
- No additional drivers or kernel extensions needed

Tested on macOS 14 (Sonoma), 15 (Sequoia), and 26 (Tahoe).

## Install

### Option A: Build from source

```bash
git clone https://github.com/StrongDeparture/retune.git
cd retune
bash build.sh
open retune.app
```

Requires Xcode Command Line Tools (`xcode-select --install`).

### Option B: Download the release

Download `retune.app.zip` from [Releases](https://github.com/StrongDeparture/retune/releases), unzip, and move to `/Applications`.

### First launch (unsigned app)

Since the app is not notarized by Apple, macOS will block it on first launch:

1. **Right-click** (or Control-click) `retune.app` and select **Open**
2. Click **Open** in the dialog that appears
3. Alternatively: go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to the Retune message

You only need to do this once. After that, it opens normally.

### Grant permission

On first run, macOS will ask to allow Retune to capture system audio. Click **Allow**. This uses the Core Audio Tap API — no microphone access, no orange dot.

## Usage

Retune appears as a **♪ icon in the menu bar**. Click it to open the panel.

**Toggle on/off** — the switch at the top starts or stops pitch shifting.

**Reference note** — pick C or A as your reference:
- **C mode**: set C4 directly (default 256 Hz). Presets: 256, 261.
- **A mode**: set A4 directly (default 432 Hz). Presets: 432, 440.

The slider lets you dial in any frequency within range. The cents offset from 440 is shown on the right.

Retune always outputs to whatever your system default audio device is. Plug in headphones, switch Bluetooth — it follows automatically.

**Settings persist** across app restarts (reference note, frequency).

## How it works

1. Creates a system-wide audio tap via `CATapDescription` (Core Audio Tap API, macOS 14.2+)
2. Reads captured audio through an IOProc on an aggregate device
3. Pipes it through `AVAudioUnitTimePitch` for pitch shifting
4. Outputs to the system default audio device

No virtual audio driver needed. No kernel extension. No microphone permission. The original audio is muted by the tap and replaced with the pitch-shifted version.

## Use cases

**Listener who prefers A=432** — Turn it on, leave it on. All your music, videos, and podcasts play in 432.

**Musician practicing along with recordings** — Set your guitar to 432 (or any reference), then retune the backing track to match. No need to re-download or convert files.

**Exploring alternative tunings** — Dial the slider to hear what C=256 (scientific pitch), A=444 (Verdi), or any other reference sounds like with your existing music library.

## FAQ

**Does it add latency?**
About 3ms at 96 kHz. Negligible for listening. Not designed for live performance monitoring.

**Does it affect recording apps?**
The tap excludes Retune's own process. Other apps that record system audio will capture the original (unmuted) stream or the shifted stream depending on their capture method.

**Can I use it with AirPods / Bluetooth headphones?**
Yes. Retune automatically follows the system default output device, so just connect your Bluetooth headphones and it switches.

**What about sample rate?**
Retune matches the output device's native sample rate automatically (44.1, 48, 96 kHz, etc.). No manual configuration needed.

**Does it work at login?**
Not yet — there's no "start at login" option. You need to open the app manually after each reboot. The frequency and reference settings are remembered.

**Why is there no orange dot?**
The Core Audio Tap API captures system audio output, not microphone input. macOS only shows the orange dot for microphone access.

## Building

```bash
# Build release binary and package into .app bundle
bash build.sh
```

The build script:
1. Runs `swift build -c release`
2. Copies the binary into `retune.app/Contents/MacOS/`
3. Copies `Info.plist` into the bundle
4. Ad-hoc codesigns the binary with entitlements

## Support

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/K3K81WK1N8)

Crypto:

- **ETH / USDT (Ethereum):** `0xe2e83b95f9085bedc61c28abd77a4c71997dd146`
- **BTC:** `bc1p8s5dhyg3e5nl4a3qfydakwn6cv4w55a9km3xzd8s9rumjqrxf9jqdmhzv6`
- **SOL:** `7kVAEjUdm1RusZ2b8Ag6HdUSGyurb9Yyu8MW1bVtGi9`

## License

[PolyForm Noncommercial 1.0.0](LICENSE) — free to use and share for noncommercial purposes. You may not sell or charge for this software or any derivative.
