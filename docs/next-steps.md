# Next Steps

## Android Build Completion

1. **Install Android Studio SDK components**
   - Launch `/home/danny/android-studio/bin/studio.sh` once.
   - Through SDK Manager, install at least one Android SDK Platform (API 33+), build-tools, and platform-tools.
   - Accept licenses via `/home/danny/flutter/bin/flutter doctor --android-licenses`.
2. **Verify toolchain**
   - Run `/home/danny/flutter/bin/flutter doctor` and ensure the Android toolchain and Studio sections are green.
3. **Build release APK locally**
   - From repo root: `cd ~/github/bpm && /home/danny/flutter/bin/flutter build apk --release`.
   - Gradle will pull dependencies on first run; keep network connected.
   - Artifact: `build/app/outputs/flutter-apk/app-release.apk`.
4. **Install on device**
   - Via USB-debugging device: `adb install -r build/app/outputs/flutter-apk/app-release.apk`.
   - Launch app, grant microphone permission, confirm BPM readings + sparkline update.

## Wavelet Accuracy Test

- Current unit test (`test/algorithms/fft_and_wavelet_algorithm_test.dart`) still reports ~13 BPM error.
- Debug plan:
  1. Instrument wavelet algorithm to log selected level/lag for synthetic signal.
  2. Compare against true tempo (96 BPM) and adjust envelope smoothing/lag scaling.
  3. When within ±4 BPM, re-run `flutter test`.

## Environment Notes

- Flutter SDK: `/home/danny/flutter`
- Android Studio: `/home/danny/android-studio`
- Ensure desktop toolchains have compilers installed (e.g., `sudo apt install build-essential clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev`).
