# Architecture Overview

This project follows the layered structure defined in [`docs/PLAN-01.md`](PLAN-01.md) and operationalized by the long‑lived agents in [`AGENTS.md`](../AGENTS.md). The goal is to keep Flutter UI concerns, application logic, DSP algorithms, and platform audio isolated so each agent can evolve their slice independently.

```
┌────────────┐
│   UI + UX  │  Flutter widgets (HomeScreen, cards, sparklines)
└─────┬──────┘
      │ Bloc state (BpmCubit/BpmState)
┌─────▼──────┐
│  App Logic │  Coordinator, repository, consensus engine
└─────┬──────┘
      │ Streams of AudioFrame / BpmSummary
┌─────▼──────┐
│ Algorithms │  Onset, Autocorr, FFT, Wavelet registry
└─────┬──────┘
      │ Raw PCM windows
┌─────▼──────┐
│  DSP & IO  │  RecordAudioStreamSource, PCM utils, record plugin
└────────────┘
```

## UI Layer

- **Widgets**: `HomeScreen`, `BpmSummaryCard`, `BpmTrendSparkline`, `AlgorithmReadingsList`.
- **State**: `BpmCubit` orchestrates the detection lifecycle; it emits `BpmState` snapshots that drive the UI.
- **Status Flow**: `DetectionStatus` maps directly to UI affordances (FAB label, banner copy, loading indicators).
- **Docs**: See [`docs/algo-overview.md`](algo-overview.md) for UX backlog and [`docs/next-steps.md`](next-steps.md) for upcoming UI polish.

## Application Logic

- **Repository** (`lib/src/repository/bpm_repository.dart`): Ties the coordinator to state management; exposes a single `listen()` stream returning `BpmSummary`.
- **Coordinator** (`lib/src/core/bpm_detector_coordinator.dart`):
  - Starts the microphone via `AudioStreamSource`.
  - Maintains a sliding buffer of `AudioFrame`s sized to `bufferWindow` (currently 10 s).
  - Triggers analysis every `analysisInterval` (~1 s) once the window is primed, yielding `DetectionStatus.buffering → analyzing → streamingResults`.
  - Fan-out to every registered algorithm (see below) and runs the `ConsensusEngine`.
- **Consensus Engine** (`lib/src/core/consensus_engine.dart`): Normalizes confidences, weights recent readings, and emits `ConsensusResult` objects that feed the UI and history chart.

## Algorithms Layer

Implemented detectors live under `lib/src/algorithms/` and share the `BpmDetectionAlgorithm` interface. Details + references in [`docs/algorithms.md`](algorithms.md). Accuracy stabilization work is tracked in [`docs/PLAN-03.md`](PLAN-03.md).

1. **Simple Onset** (`simple_onset_algorithm.dart`) — Short-time energy and peak spacing. Week‑1 PLAN‑03 updates add duration-weighted interval histograms, harmonic penalties, and richer metadata for consensus.
2. **Autocorrelation** (`autocorrelation_algorithm.dart`) — Time-domain periodicity scan.
3. **FFT Spectrum** (`fft_spectrum_algorithm.dart`) — Frequency-domain peak picking.
4. **Wavelet Energy** (`wavelet_energy_algorithm.dart`) — Multiresolution Haar bands with aggregation + fallback.

An `AlgorithmRegistry` aggregates the active algorithms; swapping additions/removals happens in `lib/src/app.dart`.

## DSP & Audio I/O

- **Stream Source** (`lib/src/audio/record_audio_stream_source.dart`):
  - Wraps `AudioRecorder` from `record` 6.x to request permission, start PCM streaming, and convert little-endian PCM16 to float samples via `PcmUtils`.
  - Emits `AudioFrame`s tagged with sequence numbers for ordering / deduplication.
- **PCM Utilities** (`lib/src/dsp/pcm_utils.dart`): Provides format conversions; extend here when introducing advanced preprocessing (DC removal, filtering, etc.).
- **Detection Context** (`lib/src/algorithms/detection_context.dart`): Carries sample rate, BPM bounds, and preferred window duration so algorithms stay parameterized.

## Knowledge & Process Artifacts

- [`docs/PLAN-01.md`](PLAN-01.md): 10-week roadmap + layered architecture spec.
- [`AGENTS.md`](../AGENTS.md): Ownership table for each lane (UI, DSP, audio, QA, etc.).
- [`docs/PROGRESS.md`](PROGRESS.md): Running milestone log; update whenever coordinator/algorithms change.
- [`docs/algorithms.md`](algorithms.md): Deep dive into signal-processing techniques plus citations.
- [`docs/algo-overview.md`](algo-overview.md): Snapshot backlog for algorithm experimentation.
- [`docs/next-steps.md`](next-steps.md): Tactical TODOs + open risks.

## Extending the System

1. **Adding Algorithms**: Implement `BpmDetectionAlgorithm`, register it in `lib/src/app.dart`, and document the approach in `docs/algorithms.md`.
2. **Changing Stream Sources**: Implement `AudioStreamSource` (e.g., file playback, synthetic sources); wire it into `BpmDetectorCoordinator`.
3. **Tuning Latency**: Adjust `bufferWindow` (window size), `analysisInterval` (how often to run detection), or algorithm-specific window preferences.
4. **Observability**: Hook into `BpmSummary` stream for logging/telemetry; emit `metadata` from algorithms to trace decisions.

By keeping each layer independent and documenting contracts between them, we can iterate on accuracy, performance, and UX without cross-coupling changes.
