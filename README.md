# BPM Detection Tool

Real-time Flutter application that captures microphone audio, runs multiple BPM detection algorithms (energy onset, autocorrelation, FFT spectrum, Haar-wavelet aggregation), and streams both individual and consensus tempo estimates. The architecture follows the layered approach defined in [`docs/PLAN-01.md`](docs/PLAN-01.md) and is tracked via the long-lived agents in [`AGENTS.md`](AGENTS.md).

### Current Status

- ✅ **Core DSP**: Four complementary detectors wired up (see [`docs/algorithms.md`](docs/algorithms.md) for full descriptions and references).
- ✅ **Real-time UI**: Consensus card + delta indicator + sparkline history are live.
- ✅ **Platform plumbing**: `record` 6.x handles microphone streaming across mobile & desktop targets.
- 🚧 **Next Up**: Accuracy benchmarking + automated regression harness (tracked in [`docs/next-steps.md`](docs/next-steps.md) and milestone updates in [`docs/PROGRESS.md`](docs/PROGRESS.md)).

## Getting Started

1. Install Flutter 3.13+ and enable iOS/Android tooling.
2. From the repo root, run `flutter pub get`.
3. Launch the app with `flutter run` (enable microphone permissions).

## Supported Platforms

The repository now includes the standard Flutter scaffolding for Android, iOS, web, macOS, Windows, and Linux (generated via `flutter create .`). Use `flutter config --enable-<platform>-desktop` as needed before running on those targets.

Key docs:

- [`AGENTS.md`](AGENTS.md) – ownership map / long-lived agents.
- [`docs/PLAN-01.md`](docs/PLAN-01.md) – master implementation plan & architecture layers.
- [`docs/algorithms.md`](docs/algorithms.md) – signal-processing approaches & citations.
- [`docs/next-steps.md`](docs/next-steps.md) – near-term engineering focus.
- [`docs/PROGRESS.md`](docs/PROGRESS.md) – milestone log (append every major update).

## Deploying to an Android Phone

1. **Prep tooling**
   - Install Android Studio (or standalone Android SDK + platform-tools) and ensure at least one API 33+ platform + build-tools are present.
   - Accept SDK licenses via `flutter doctor --android-licenses` and confirm `flutter doctor` shows no red errors.
2. **Enable your device**
   - On the phone, enable *Developer options* → *USB debugging* (or *Wireless debugging* if using Wi-Fi pairing) and unplug/replug USB so ADB trusts the host.
   - Verify Flutter sees the device: `flutter devices` should list e.g. `Pixel_7 (android-arm64)`.
3. **Install a debug/dev build directly**
   - From the repo root run `flutter pub get` if you haven’t already.
   - Start the app on the phone with `flutter run -d <deviceId>` (use `--release` for production-like perf). Grant microphone permission when prompted.
4. **Produce an installable APK**
   - Run `flutter build apk --release`. The artifact lands at `build/app/outputs/flutter-apk/app-release.apk`.
   - Install it with `adb install -r build/app/outputs/flutter-apk/app-release.apk` (enable “Install unknown apps” on the device if needed).
   - For Play Store delivery, create a signing keystore and configure `android/key.properties`, then prefer `flutter build appbundle` for an `.aab`.
5. **Post-install checks**
   - Open the app, allow microphone access, and verify real-time BPM readings appear under both the consensus card and algorithm breakdown list.
   - If algorithms run but audio is silent, confirm the phone’s input gain isn’t muted and the session uses the device’s sample rate (see `AudioStreamConfig` in code for tuning).
