# BPM Detection Algorithms

This document summarizes the signal-processing approaches currently implemented in the Flutter BPM Detection tool. Each section links the practical implementation choices in `lib/src/algorithms` with the canonical techniques they were derived from so new contributors understand the trade-offs.

## Layered Overview

1. **Audio Capture & Preprocessing** — `RecordAudioStreamSource` pulls mono float frames from the microphone, normalizes them, and hands them to the coordinator in fixed windows (`AudioStreamConfig`).
2. **Algorithm Registry** — `AlgorithmRegistry` fans each sliding window into multiple detection strategies (`SimpleOnsetAlgorithm`, `AutocorrelationAlgorithm`, `FftSpectrumAlgorithm`, `WaveletEnergyAlgorithm`). Each implementation owns its preferred window size and emits a `BpmReading`.
3. **Consensus Engine** — `ConsensusEngine` weights algorithm outputs by confidence and recency before surfacing a single `ConsensusResult`. This keeps the UI stable even if any one method momentarily misfires.

## Energy Onset (Transient) Detection

- **Implementation**: `lib/src/algorithms/simple_onset_algorithm.dart`
- **Idea**: Converts time-domain samples into short-time energy envelopes, thresholds local peaks, and converts inter-peak intervals into BPM estimates.
- **Key Steps**:
  - Flatten all frames, compute frame energy (`samples²` summed over `frameMillis` windows).
  - Normalize the envelope, keep peaks above 0.6 relative amplitude.
  - **PLAN‑03 Week 1**: build duration-weighted histograms of inter-peak intervals (20 ms bins), down-weight faster harmonics, normalize the winning bucket into the `[minBpm, maxBpm]` range, and fall back to the median interval when harmonics dominate.
  - Confidence blends inter-beat variance with histogram agreement (bucket strength/supporter ratio) and records correction metadata for the consensus/UI layers.
- **References**:
  - D. Ellis, *“Beat Tracking by Dynamic Programming,”* ISMIR 2007 — describes transient-based beat inference.
  - A. Brossier, *“Automatic Annotation of Musical Audio for Interactive Applications,”* PhD thesis, 2006 — foundation for energy-based onset detection.

**Usage Notes**: Works best on percussive material with clear kick/snare accents. Adjust `frameMillis` for finer temporal precision (smaller windows) or better noise resistance (larger windows). Provide realistic `DetectionContext` bounds—the histogram normalizes to the closest BPM inside that window, and metadata highlights when a median/normalization correction occurred.

## Autocorrelation (Time-Domain Periodicity)

- **Implementation**: `lib/src/algorithms/autocorrelation_algorithm.dart`
- **Idea**: Runs autocorrelation on the onset-envelope stream, then applies the same inter-interval histogramming used by the onset detector to suppress harmonic lags.
- **Key Steps**:
  - Consume the precomputed onset novelty curve (~100 Hz) and normalize it to remove DC/scale differences.
  - Compute autocorrelation for lags between `minLag` and `maxLag` derived from `minBpm/maxBpm` with dense sampling and refinement.
  - Push lag-derived intervals through the histogram/clustering helper so the dominant bucket favours the fundamental over half/double tempos; fall back to direct harmonic coercion only if the histogram fails.
  - Confidence blends the autocorrelation peak score, histogram cluster strength, and lag contrast.
- **References**:
  - E. D. Scheirer, *“Tempo and Beat Analysis of Acoustic Musical Signals,”* JASA 103(1), 1998.
  - F. Gouyon & S. Dixon, *“A Review of Automatic Rhythm Description Systems,”* Computer Music Journal 29(1), 2005.

**Usage Notes**: Feeding the onset envelope makes the algorithm robust to broadband noise and lets it share preprocessing work with other detectors. Lag ranges remain critical—set realistic `minBpm/maxBpm` bounds to keep the histogram from normalizing to implausible tempos.

## FFT Magnitude Spectrum

- **Implementation**: `lib/src/algorithms/fft_spectrum_algorithm.dart` (runtime FFT in `lib/src/dsp/fft_utils.dart`)
- **Idea**: Frequency-domain approach that identifies dominant low-frequency peaks in the magnitude spectrum of the energy envelope.
- **Key Steps**:
  - Normalize samples, zero-pad to the next power-of-two >= window length.
  - Apply Hann window to reduce spectral leakage.
  - Downsample to ~16 kHz, Hann window, and run the in-app radix-2 FFT helper (`FftUtils.magnitudeSpectrum`) to recover the low-frequency beat envelope.
  - Translate bin index to BPM (`frequency * 60`), track strongest magnitude inside `[minBpm, maxBpm]`, and fall back to the raw peak when refinement drifts to 3/2 or 2× harmonics (fundamental guard).
  - Confidence compares peak magnitude with average spectral energy.
- **References**:
  - G. Tzanetakis & P. Cook, *“Musical Genre Classification of Audio Signals,”* IEEE TASLP 10(5), 2002 — uses spectral periodicity for rhythm features.
  - A. Klapuri et al., *“Multipitch Analysis of Harmonic Sound Signals Based on Spectral Flattening and Subharmonic Summation,”* IEEE TASLP 11(6), 2003 — foundational for harmonic sum approaches.

**Usage Notes**: Works well on steady-state dance tracks. Ensure `fftSize` spans at least 8–12 seconds to get sub-1 BPM resolution when targeting low tempos; the guard keeps consensus aligned with the fundamental even when harmonic peaks dominate.

## Wavelet Energy Bands + Aggregation

- **Implementation**: `lib/src/algorithms/wavelet_energy_algorithm.dart`
- **Idea**: Applies a multiresolution Haar transform, analyzes detail-band energy envelopes, and aggregates candidate periodicities to improve robustness on noisy material.
- **Key Steps**:
  - Downsample to a 400 Hz working rate, normalize, and trim audio to a power-of-two length.
  - Perform iterative Haar decomposition, storing detail bands up to `levels`.
  - For each detail level:
    - Compute absolute energy, smooth with adaptive windows, remove DC, normalize.
    - Upsample to match original length and accumulate weighted envelopes (`1/scale` weighting).
    - Run autocorrelation within BPM-aware lag bounds; track best lag per level with scale-aware weighting.
  - Combine best per-level candidate with the aggregated (averaged) envelope, keeping literal tempo candidates (no harmonic expansion).
  - Fallback: If both disagree or are out-of-range, analyze a high-resolution absolute envelope of the raw signal.
  - Metadata captures whether aggregate/fallback logic overrode the level-specific pick, aiding debugging.
- **References**:
  - G. Tzanetakis, *“Percussive Audio Transcription using Wavelets and Metrical Models,”* ICMC 2001.
  - M. E. P. Davies & M. D. Plumbley, *“Context-Dependent Beat Tracking of Musical Audio,”* IEEE TASLP 15(3), 2007 — multiband energy tracking with autocorrelation consensus.
  - S. Mallat, *“A Wavelet Tour of Signal Processing,”* Academic Press, 2008 — general background on wavelet coefficient interpretation.

**Usage Notes**: Tunable parameters include number of levels, smoothing windows, and weighting heuristics. Increasing levels improves sensitivity to slower tempos but raises compute cost. The downsampled workflow and literal candidates keep runtime below 0.3 s on mobile while avoiding 1.5×/2× lock-ins.

## Tempogram & Predominant Local Pulse (PLP)

- **Implementation**: `lib/src/dsp/tempogram.dart`, exposed via `PreprocessedSignal.tempogram` and wired into `BpmDetectorCoordinator` / `BpmSummary`.
- **Idea**: Extend preprocessing with a tempo–time heatmap (tempogram) derived from the spectral-flux novelty curve and feed the predominant local pulse (PLP) into consensus and UI layers.
- **Key Steps**:
  - Compute a sliding DFT of the novelty curve (8 s window, 1 s hop) to populate tempo bins between 50–250 BPM.
  - Track the dominant tempo per frame plus a strength metric (contrast vs. next-best bin).
  - Emit tempogram matrices, tempo axis, frame times, and PLP trace to the coordinator.
  - Introduce a synthetic `plp_tempogram` reading whose confidence scales with PLP strength—consensus treats it as an auxiliary vote when primary detectors disagree, and the UI shows the PLP panel for transparency.
- **References**:
  - F. Grosche & M. Müller, *“Tempogram Toolbox: MATLAB Implementations for Tempo and Pulse Analysis of Music Recordings,”* ISMIR 2011.
  - M. Müller, *Fundamentals of Music Processing*, Springer, 2015 — Chapter on tempograms and PLP curves.

**Usage Notes**: Tempogram updates reuse preprocessing work so the overhead stays modest (<25 ms per hop). The PLP trace and strength power the new UI panel and provide consensus with a low-weight stabiliser when onset/autocorrelation disagree.

## Consensus & Confidence Handling

- **Implementation**: `lib/src/core/consensus_engine.dart`
- **Approach**: Weighted median of available BPM readings plus the PLP vote, with weights derived from:
  - Reported confidences (normalized per algorithm) and per-reading “cluster consistency” metadata.
  - Algorithm coverage (how many detectors agree within the winning cluster).
  - Harmonic correction flags (median/boundary/octave adjustments reduce weight).
  - PLP strength (auxiliary vote only nudges consensus when its contrast is strong).
- **References**:
  - A. Holzapfel & Y. Stylianou, *“Beat Tracking using Joint Beat and Rhythm Salience,”* IEEE TASLP 19(1), 2011 — demonstrates combining heterogeneous rhythmic cues.
  - J. McGraw & R. Fiebrink, *“Systematic Evaluation of Real-Time Beat Trackers,”* NIME 2014 — motivates multi-algorithm fusion.

## Future Work & Extensions

- **Probabilistic Tempo Models**: Incorporate tempo dynamics (e.g., particle filters or Bayesian tempo trackers as in Bello & Ellis 2005) to smooth per-window jitter.
- **Neural Frontends**: Replace handcrafted features with lightweight CNN onset detectors (`Madmom`-style) when NN inference is viable on-device.
- **Adaptive Buffering**: Allow algorithms to request longer input windows (e.g., 20–30 s) when confidences remain low, trading latency for accuracy.
- **Tempogram Visualisation**: Complete the plan in `docs/TEMPOGRAM-UI-SCOPE.md` to render the tempogram/PLP data directly and expose toggleable per-algorithm overlays.
- **Tempo-Harmonic Reasoning**: Extend consensus metadata so downstream consumers (e.g., logging/UI) can distinguish half/double-tempo clusters vs. outright disagreement when more detectors come online.

## Reference List

1. Scheirer, E. D. “Tempo and Beat Analysis of Acoustic Musical Signals.” *JASA* 103(1), 1998.
2. Gouyon, F., & Dixon, S. “A Review of Automatic Rhythm Description Systems.” *Computer Music Journal* 29(1), 2005.
3. Ellis, D. P. W. “Beat Tracking by Dynamic Programming.” *ISMIR*, 2007.
4. Brossier, P. “Automatic Annotation of Musical Audio for Interactive Applications.” PhD Thesis, Queen Mary Univ. of London, 2006.
5. Tzanetakis, G., & Cook, P. “Musical Genre Classification of Audio Signals.” *IEEE TASLP* 10(5), 2002.
6. Davies, M. E. P., & Plumbley, M. D. “Context-Dependent Beat Tracking of Musical Audio.” *IEEE TASLP* 15(3), 2007.
7. Mallat, S. *A Wavelet Tour of Signal Processing.* Academic Press, 2008.
8. Holzapfel, A., & Stylianou, Y. “Beat Tracking using Joint Beat and Rhythm Salience.” *IEEE TASLP* 19(1), 2011.
9. McGraw, J., & Fiebrink, R. “Systematic Evaluation of Real-Time Beat Trackers.” *NIME*, 2014.
