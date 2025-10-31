# BPM Detection Tool — Agent Context Guide

This document provides essential context for AI agents and contributors working on the Flutter BPM detection codebase. It consolidates key information from README, PLAN-03, algorithms.md, and PROGRESS.md to help agents understand the project state, architecture, and current focus areas.

## Project Overview

Real-time Flutter application that captures microphone audio and runs multiple BPM detection algorithms (energy onset, autocorrelation, FFT spectrum, Haar-wavelet aggregation). The architecture follows a layered approach: UI → Logic → Algorithms → DSP → Audio I/O.

**Build-upload-test cycle takes a long time; plan ahead and make every revision count.**

## Current Project State (as of 2025-10-31)

### What's Working
- ✅ Four complementary detectors implemented and passing tests
- ✅ Preprocessing pipeline with shared novelty curve, onset envelope, STFT, and tempogram
- ✅ Tempogram/PLP integration: preprocessing publishes tempogram snapshots and PLP readings
- ✅ Real-time UI with consensus card, delta indicator, sparkline history, elapsed timer, and PLP panel
- ✅ Platform plumbing via `record` 6.x for microphone streaming

### Current Issues & Focus Areas
- **Wavelet Algorithm**: Generally accurate but tolerance handling has issues
  - `percentTolerance` not applying correctly in tests; still showing old fixed tolerance in failure messages
  - Need debug prints for computed allowed tolerance to verify test execution values
- **Consensus Algorithm**: Not currently very good; needs metadata-weighted improvements (PLAN-03 Phase B)
- **Predominant Pulse (PLP)**: Recently added, needs proper integration to make UI consistent
- **Test Infrastructure**: Using synthesized audio and data files under `data/` (metronome_55.wav, metronome_105.wav, metronome_155.wav, metronome_205.wav)

### Active Development (PLAN-03 Week 1)
- Interval histogram refinement with duration-weighted bins and harmonic penalties
- Per-reading metadata (bucket scores, multipliers, supporter counts) surfaced to consensus
- Histogram weighting + harmonic suppression in Autocorrelation and FFT
- Wavelet downsampled to 400 Hz with confidence remapping

## Architecture Layers

1. **Audio Capture & Preprocessing** — `RecordAudioStreamSource` pulls mono float frames, normalizes them, hands to coordinator in fixed windows
2. **Preprocessing Pipeline** (`lib/src/dsp/preprocessing.dart`) — Generates `PreprocessedSignal` with:
   - Normalized samples
   - Onset novelty curve (~100 Hz)
   - STFT data
   - Tempogram (tempo-time heatmap) with PLP trace
3. **Algorithm Registry** (`lib/src/algorithms/`) — Four detectors process `PreprocessedSignal`:
   - `SimpleOnsetAlgorithm` — Energy envelope with duration-weighted histograms
   - `AutocorrelationAlgorithm` — Time-domain periodicity on onset envelope
   - `FftSpectrumAlgorithm` — Frequency-domain with fundamental guard
   - `WaveletEnergyAlgorithm` — Multiresolution Haar transform (400 Hz, 2 levels)
4. **Consensus Engine** (`lib/src/core/consensus_engine.dart`) — Weighted median of readings plus PLP vote, considers:
   - Confidence, cluster consistency, algorithm coverage
   - Harmonic correction flags (reduce weight for median/boundary/octave adjustments)
   - PLP strength (auxiliary vote when primary detectors disagree)
5. **Coordinator** (`lib/src/core/bpm_detector_coordinator.dart`) — Runs preprocessing once per cycle, distributes `PreprocessedSignal` to algorithms
6. **UI Layer** — Binds streams to widgets, displays consensus + per-algorithm results + PLP panel

## Key Files & Locations

- **Algorithms**: `lib/src/algorithms/` (simple_onset, autocorrelation, fft_spectrum, wavelet_energy)
- **DSP Utilities**: `lib/src/dsp/` (preprocessing.dart, fft_utils.dart, tempogram.dart, signal_utils.dart)
- **Consensus**: `lib/src/core/consensus_engine.dart`
- **Coordinator**: `lib/src/core/bpm_detector_coordinator.dart`
- **Test Fixtures**: `data/metronome_*.wav` files (55, 105, 155, 205 BPM)
- **Integration Tests**: `test/integration/` (metronome_wav_test.dart, etc.)
- **Documentation**: `docs/` (PLAN-03.md, algorithms.md, PROGRESS.md, architecture.md)

## Testing Strategy

- **Unit Tests**: Synthetic signals for each algorithm
- **Integration Tests**: Real WAV fixtures under `data/` directory
  - Metronome suite: 55, 105, 155, 205 BPM
  - Tests use `percentTolerance` parameter for flexible accuracy bounds
- **Current Test Issue**: Wavelet tolerance not applying `percentTolerance` correctly; showing old fixed tolerance in failures
- **Validation Goal**: ≥90% of WAV fixtures within ±3 BPM for steady signals; ≥80% within ±5 BPM for complex signals

## Common Development Tasks

### Running Tests
```bash
flutter test                                    # All tests
flutter test test/integration/metronome_wav_test.dart  # Specific integration test
flutter analyze                                 # Static analysis
```

### Building for Android
```bash
flutter build apk --release                     # Release APK
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

### Adding Debug Prints
When debugging test issues (like current tolerance problem), add prints in test files or algorithm implementations to trace computed values during execution.

## PLAN-03 Roadmap (Accuracy Stabilization)

### Week 1 (Current): Interval & Harmonic Refinement
- ✅ Histogram-based fundamental selector with duration weighting
- ✅ Harmonic penalties for multipliers > 1
- ✅ Autocorrelation and FFT histogram integration
- ✅ Wavelet downsampling to 400 Hz
- 🔍 Next: Integrate Tempogram Toolbox bandwise spectral-flux novelty curve

### Week 2: Consensus Intelligence
- Metadata-weighted consensus scoring
- Confidence semantics refresh (High/Medium/Low tiers)
- PLP integration as auxiliary consensus source

### Week 3: Validation & Tooling
- Expand WAV fixture suite (steady metronome, live drum loop, electronic, tempo ramp, noise)
- CLI harness (`tool/bpm_wav_regression.dart`)
- CI integration with JSON/Markdown reporting

### Week 4: UX & Observability
- Display consensus confidence tier
- Show harmonic correction indicators
- Optional telemetry for field debugging

## Algorithm-Specific Notes

### SimpleOnsetAlgorithm
- Uses duration-squared histogram bins with aggressive harmonic penalties
- Fundamental tie-breakers favor slower buckets
- Confidence blends inter-beat variance with histogram agreement

### AutocorrelationAlgorithm
- Runs on onset envelope with calibrated confidence
- Histogram/clustering suppresses harmonic lags
- Lag ranges critical: set realistic minBpm/maxBpm bounds

### FftSpectrumAlgorithm
- Fundamental guard prevents 3/2 or 2× harmonic drift
- Ensure fftSize spans 8-12 seconds for sub-1 BPM resolution

### WaveletEnergyAlgorithm
- 400 Hz working rate, 2 levels (downsampled from 4 for performance)
- Literal tempo candidates (no harmonic expansion)
- Metadata captures aggregate/fallback logic for debugging
- **Current issue area**: tolerance handling in tests

## Collaboration Norms

1. Every major milestone/update should append an entry to `docs/PROGRESS.md` with owner + timestamp
2. When handing off work, note outstanding risks, artifacts, and verification steps
3. Reference PLAN-01/PLAN-03 requirements when proposing scope or architectural changes
4. Build-upload-test cycle is expensive; test locally and plan changes carefully

## Immediate Next Steps

1. Debug wavelet tolerance issue: add prints for computed allowed tolerance in tests
2. Integrate Predominant Pulse display properly in UI
3. Continue consensus algorithm improvements (metadata weighting)
4. Expand WAV fixture coverage beyond metronomes