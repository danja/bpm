# Linux WAV Test Rig Evaluation

## Goals
- Replay real-music `.wav` fixtures on Linux hosts and feed them through the existing preprocessing + algorithm stack.
- Produce repeatable accuracy and performance metrics (per algorithm and consensus) to unblock regression testing before Android releases.
- Keep the harness lightweight so it can run in CI once Linux runners are available.

## Current State
- Unit tests use synthetic waveforms generated in `test/support/signal_factory.dart`; there is no file-based ingestion path yet.
- `PreprocessingPipeline` plus the individual algorithms already accept in-memory `AudioFrame` buffers, so an offline harness only needs to load samples and wrap them in frames.
- No package for decoding PCM `.wav` files is included in `pubspec.yaml`, and there is no manifest for ground-truth tempos.

## Required Capabilities
1. **WAV decoding** – Convert 16-bit PCM (mono/stereo) into `Float32List`. Preferred: add a pure-Dart dependency such as `package:wav` (reads RIFF headers, supports interleaved channels). Fallback: shell out to `ffmpeg -f f32le` if native dependency is acceptable.
2. **Framing utilities** – Reuse or extend `SignalFactory.framesFromSamples` to chunk decoded samples into `AudioFrame`s using the configured frame size (default 2048 samples).
3. **Batch runner** – Command-line Dart entry point (e.g. `tool/bpm_wav_benchmark.dart`) that:
   - Reads a manifest (JSON/TOML) describing fixtures, expected BPM, and tolerance.
   - Loads audio, runs the preprocessing pipeline once, executes selected algorithms (`SimpleOnset`, `Autocorrelation`, `FftSpectrum`, `WaveletEnergy`), and captures timing + confidence.
   - Emits a summary table plus machine-readable output (JSON) for CI assertions.
4. **Ground-truth management** – Store fixtures under `assets/audio/fixtures/real_music/` (git-lfs recommended). Accompany each file with metadata (`fixtures_manifest.json`) listing canonical BPM, meter, and notes about tempo drift.
5. **Result assertions** – Define pass criteria per algorithm (e.g. ≤±2 BPM for consensus, ≤±4 BPM per algorithm, minimum confidence threshold) and optional octave-correction checks.

## Linux Host Setup
- Ensure Flutter/Dart SDK is available (already documented in `docs/next-steps.md`).
- Install audio tooling for asset preparation (optional but useful):
  - `sudo apt install ffmpeg sox`
  - Use `ffmpeg -i input.mp3 -ar 44100 -ac 1 output.wav` to standardize fixtures.
- For local latency benchmarks, enable CPU governor control (`sudo apt install cpufrequtils`) to pin clock speeds, though accuracy scripts can run without it.

## Implementation Plan
1. **Audio loader**
   - Add `package:wav` (or similar pure-Dart decoder) to `pubspec.yaml`.
   - Implement `WavFileAudioStreamSource` under `lib/src/audio/` that exposes decoded frames via `AudioStreamSource.frames`, matching coordinator expectations.
   - Support mono & stereo by downmixing to single channel using existing PCM utilities.
2. **Fixture manifest**
   - Create `fixtures/real_music/manifest.json` with entries:
     ```json
     {
       "fixtures": [
         {
           "path": "assets/audio/fixtures/real_music/edm_128bpm.wav",
           "bpm": 128.0,
           "tolerance": 1.5,
           "notes": "Steady four-on-the-floor"
         }
       ]
     }
     ```
   - Keep metadata small so it can be bundled with repo history; large binaries can live separately and be symlinked locally if licensing restricts distribution.
3. **CLI harness**
   - Add `tool/bpm_wav_benchmark.dart` that accepts `--manifest`, `--algorithms`, `--output-json`, `--profile`.
   - Instantiate `DetectionContext` using manifest hints (min/max BPM).
   - For each fixture, create frames, call `PreprocessingPipeline.process`, and invoke desired algorithms sequentially (or in isolates to mirror app behavior).
   - Aggregate timings with `Stopwatch` to detect regressions.
4. **Automated tests**
   - Add a targeted `dart test` (e.g. `test/integration/real_fixtures_test.dart`) gated behind `@Tags(['requires-fixtures'])` so it can be skipped when fixtures are absent.
   - In CI, mount fixtures via artifact storage and run `dart run tool/bpm_wav_benchmark.dart --manifest fixtures/... --assert`.
5. **Reporting**
   - Generate Markdown/CSV summary after each run and append key metrics to `docs/PROGRESS.md` when significant regressions or improvements are observed.

## Risks & Mitigations
- **Dataset licensing** – Use Creative Commons or self-recorded loops to avoid legal issues; document provenance in the manifest.
- **Large fixture size** – Prefer short (10–20 s) excerpts; use git LFS or instruct developers to download separately.
- **Algorithm drift due to tempo variation** – Annotate tracks with tempo maps if they include tempo ramps; for now prioritize steady-tempo genres.
- **Environment differences** – Normalize floating-point tolerances and ensure deterministic decoding by resampling fixtures to 44.1 kHz mono.

## Next Actions
1. Select 5–10 representative tracks (electronic, rock, hip-hop, live drums) and capture canonical BPM values.
2. Add WAV decoder dependency and implement `WavFileAudioStreamSource`.
3. Build the CLI harness + manifest format and land initial fixtures.
4. Document run instructions in `README.md` and wire into CI or a dedicated `make test-fixtures` target.
