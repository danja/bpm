# PLAN-02: Three-Phase Architecture & Algorithm Improvements

**Document Owner**: DSP & Algorithms Engineer + Solution Architect
**Created**: 2025-10-30
**Status**: Draft
**Supersedes**: Extends PLAN-01 with enhanced algorithm architecture

## Executive Summary

This plan proposes a **three-phase architecture** (Pre-processing → Algorithm → Post-processing) to address current algorithm failures and improve BPM detection accuracy. Currently only `SimpleOnsetAlgorithm` works; `AutocorrelationAlgorithm` times out, `FftSpectrumAlgorithm` crashes on ARM, and `WaveletEnergyAlgorithm` is too slow. By introducing a shared preprocessing pipeline and post-processing refinement layer, we can:

1. Eliminate redundant computations across algorithms
2. Improve signal quality before analysis
3. Fix broken algorithms through better DSP utilities
4. Establish comprehensive test fixtures for quality assurance

## Current State Analysis

### Algorithm Status

| Algorithm | Status | Issue | Impact |
|-----------|--------|-------|--------|
| SimpleOnsetAlgorithm | ✅ Working | None | Only algorithm in production |
| AutocorrelationAlgorithm | ❌ Disabled | Times out (>5s) | Missing robust periodicity detection |
| FftSpectrumAlgorithm | ❌ Disabled | ARM "Illegal instruction" crash | Missing frequency-domain analysis |
| WaveletEnergyAlgorithm | ⚠️ Limited | Compute-bound, 8s timeout | Runs infrequently, delayed results |

### Architectural Gaps

1. **No Shared Preprocessing**: Each algorithm independently normalizes, downsamples, and filters
2. **Redundant Computations**: Same DSP operations computed 4x per analysis cycle
3. **Missing DSP Utilities**: No bandpass filtering, spectral flux, noise reduction, or STFT
4. **Limited Post-Processing**: Consensus engine operates on raw BPM readings without refinement
5. **Test Coverage**: Working algorithm has no tests; broken algorithms have basic tests

### Performance Constraints

- **5-second timeout** on main algorithm batch (coordinator:218-226)
- **8-second timeout** on wavelet with 2-second minimum interval
- **Target hardware**: Android ARM devices
- **Real-time requirement**: Must keep pace with audio stream (1-second analysis intervals)

## Proposed Three-Phase Architecture

### Phase 1: Pre-Processing Pipeline

**Purpose**: Compute shared features once before distributing to algorithms

**Location**: New file `lib/src/dsp/preprocessing_pipeline.dart`

**Input**: `List<AudioFrame>` raw audio buffer
**Output**: `PreprocessedSignal` data class

```dart
class PreprocessedSignal {
  // Core signal representations
  final Float32List rawSamples;           // Original samples
  final Float32List normalizedSamples;    // RMS-normalized
  final Float32List filteredSamples;      // Bandpass 20-1500 Hz

  // Onset/beat detection features
  final Float32List onsetEnvelope;        // Energy-based onset strength
  final Float32List spectralFlux;         // STFT frame-to-frame flux

  // Downsampled variants for efficiency
  final Float32List samples8kHz;          // For autocorrelation
  final Float32List samples400Hz;         // For FFT tempo analysis

  // Metadata
  final int originalSampleRate;
  final Duration duration;
  final DetectionContext context;
}
```

**Processing Steps** (based on `docs/preprocessing.md`):

1. **Normalization**: RMS normalization to -18 dBFS target level
2. **DC Removal**: High-pass filter at 20 Hz to eliminate offset
3. **Bandpass Filtering**: Focus on rhythmic content (20-1500 Hz)
4. **Onset Envelope Calculation**: Short-time energy with adaptive smoothing
5. **Spectral Flux Calculation** (optional): STFT-based frame differentiation
6. **Downsampling**: Pre-compute 8kHz and 400Hz variants for efficiency
7. **Noise Floor Estimation**: Calculate RMS noise for adaptive thresholding

**Benefits**:
- Compute once, use many times (4x efficiency gain)
- Consistent signal quality across algorithms
- Centralized place to tune preprocessing parameters
- Easier debugging and profiling

### Phase 2: Algorithm Execution (Enhanced)

**Purpose**: Apply algorithm-specific tempo detection logic to preprocessed signal

**Modified Interface**: `lib/src/algorithms/bpm_detection_algorithm.dart`

```dart
abstract class BpmDetectionAlgorithm {
  String get id;
  String get label;
  Duration get preferredWindow;

  // NEW: Algorithms receive preprocessed signal
  Future<BpmReading?> analyze({
    required PreprocessedSignal signal,
    required DetectionContext context,
  });

  // OPTIONAL: Algorithm can request specific preprocessing features
  PreprocessingRequirements get requirements => PreprocessingRequirements.standard();
}
```

**Algorithm Improvements**:

#### SimpleOnsetAlgorithm
- Use pre-computed `onsetEnvelope` instead of calculating energy
- Focus on peak picking and interval analysis
- **Expected speedup**: 30-40% (skip redundant energy calculation)

#### AutocorrelationAlgorithm
- Use pre-downsampled `samples8kHz`
- Apply onset envelope as weighting function (emphasize beat positions)
- Reduce search range using onset interval hints
- **Target**: <3 seconds execution (currently times out at 5s)

#### FftSpectrumAlgorithm
- Use pre-downsampled `samples400Hz`
- **Fix ARM crash**: Replace custom FFT with platform-optimized library (`fftea` package)
- Apply onset envelope before FFT to emphasize periodicity
- **Target**: <2 seconds execution, no crashes

#### WaveletEnergyAlgorithm
- Reduce decomposition from 4 levels to 2-3 levels
- Use pre-filtered signal to reduce noise sensitivity
- Simplify candidate selection (remove multi-pass refinement)
- **Target**: <5 seconds execution (down from 8s)

### Phase 3: Post-Processing & Refinement

**Purpose**: Refine algorithm outputs and improve consensus quality

**Location**: Enhanced `lib/src/core/consensus_engine.dart`

**Post-Processing Steps**:

1. **Tempo Normalization**: Correct octave errors (half/double tempo)
2. **Beat Grid Validation**: Check if BPM produces consistent beat grid
3. **Confidence Recalibration**: Adjust confidence based on:
   - Agreement with other algorithms
   - Consistency over time windows
   - Signal quality metrics (SNR, onset clarity)
4. **Outlier Detection**: Statistical outlier removal with MAD (median absolute deviation)
5. **Temporal Smoothing**: Exponential smoothing with adaptive factor
6. **Multi-Hypothesis Tracking**: Maintain 2-3 tempo hypotheses when uncertain

**New Output**: `RefinedBpmResult`

```dart
class RefinedBpmResult {
  final double bpm;
  final double confidence;
  final List<double> beatTimes;           // NEW: Beat positions in seconds
  final TempoStability stability;         // NEW: Stable/accelerating/decelerating
  final List<BpmHypothesis> alternatives; // NEW: Alternative tempo candidates
  final Map<String, double> algorithmWeights; // Algorithm contribution
}
```

## Enhanced DSP Utilities

### New Files

#### `lib/src/dsp/filtering.dart`
```dart
// Bandpass filter (20-1500 Hz for rhythmic content)
Float32List bandpassFilter(Float32List samples, int sampleRate, {
  double lowCutoff = 20.0,
  double highCutoff = 1500.0,
});

// Gammatone filterbank (psychoacoustic subband decomposition)
List<Float32List> gammatoneFilterbank(Float32List samples, int sampleRate, {
  int numBands = 8,
  double minFreq = 20.0,
  double maxFreq = 1500.0,
});

// High-pass filter (DC removal)
Float32List highpassFilter(Float32List samples, int sampleRate, double cutoffHz);
```

#### `lib/src/dsp/stft.dart`
```dart
// Short-Time Fourier Transform
class STFT {
  final int fftSize;
  final int hopSize;
  final WindowFunction window;

  List<Float32List> forward(Float32List samples);
  Float32List spectralFlux(List<Float32List> spectrogram);
}
```

#### `lib/src/dsp/onset_detection.dart`
```dart
// Energy-based onset envelope
Float32List energyOnsetEnvelope(Float32List samples, int sampleRate, {
  Duration frameSize = const Duration(milliseconds: 30),
  Duration hopSize = const Duration(milliseconds: 10),
});

// Spectral flux onset envelope
Float32List spectralFluxOnsetEnvelope(Float32List samples, int sampleRate);

// Adaptive peak picking
List<int> pickPeaks(Float32List envelope, {
  double adaptiveThreshold = 0.3,
  Duration minInterval = const Duration(milliseconds: 300),
});
```

#### `lib/src/dsp/normalization.dart`
```dart
// RMS normalization to target level
Float32List normalizeRMS(Float32List samples, {double targetDbFS = -18.0});

// Peak normalization
Float32List normalizePeak(Float32List samples, {double targetPeak = 0.9});

// Dynamic range compression
Float32List compress(Float32List samples, {
  double threshold = 0.5,
  double ratio = 4.0,
});
```

### Enhanced Existing Files

#### `lib/src/dsp/signal_utils.dart`
- **Keep**: `downsample()`, `autocorrelation()`, `dominantLag()`
- **Improve**: Add decimation-based downsampler (higher quality)
- **Add**: `calculateRMS()`, `estimateNoiseFloor()`, `medianFilter()`

#### `lib/src/dsp/fft_utils.dart`
- **Replace**: Custom FFT with `fftea` package (platform-optimized, no ARM crash)
- **Keep**: Magnitude spectrum extraction
- **Add**: Power spectrum, phase spectrum, inverse FFT

## Test Fixture Infrastructure

### Test Data Organization

```
test/
  fixtures/
    audio/
      synthetic/
        silence_1s_44100hz.wav
        sine_440hz_1s_44100hz.wav
        click_track_120bpm_10s_44100hz.wav
        beat_signal_60bpm_5s_44100hz.wav
        beat_signal_120bpm_5s_44100hz.wav
        beat_signal_180bpm_5s_44100hz.wav
      real/
        rock_138bpm_30s.mp3
        edm_128bpm_30s.mp3
        jazz_92bpm_30s.mp3
        classical_variable_tempo_30s.mp3
    preprocessed/
      (cached preprocessed signals for speed)

  dsp/
    filtering_test.dart
    stft_test.dart
    onset_detection_test.dart
    normalization_test.dart
    signal_utils_test.dart
    fft_utils_test.dart

  algorithms/
    simple_onset_algorithm_test.dart
    autocorrelation_algorithm_test.dart
    fft_spectrum_algorithm_test.dart
    wavelet_energy_algorithm_test.dart
    preprocessing_pipeline_test.dart

  core/
    consensus_engine_test.dart
    bpm_detector_coordinator_test.dart

  integration/
    end_to_end_detection_test.dart
    performance_benchmark_test.dart
```

### Synthetic Signal Generator Enhancement

**Enhance**: `lib/src/dsp/signal_factory.dart`

```dart
class SignalFactory {
  // Existing
  static List<AudioFrame> beatSignal(...);

  // NEW: More realistic signals
  static List<AudioFrame> clickTrack({
    required double bpm,
    required Duration duration,
    int sampleRate = 44100,
  });

  static List<AudioFrame> complexRhythm({
    required double bpm,
    required Duration duration,
    List<double> beatPattern = const [1.0, 0.5, 0.75, 0.5], // Intensity pattern
    double noiseLevel = 0.0,
    int sampleRate = 44100,
  });

  static List<AudioFrame> syntheticMusic({
    required double bpm,
    required Duration duration,
    bool includeHarmonics = true,
    bool includeBass = true,
    double noiseLevel = 0.1,
    int sampleRate = 44100,
  });

  // Noise generators
  static List<AudioFrame> whiteNoise(Duration duration, int sampleRate);
  static List<AudioFrame> silence(Duration duration, int sampleRate);
  static List<AudioFrame> sineWave(double frequency, Duration duration, int sampleRate);
}
```

### Test Coverage Requirements

| Component | Target Coverage | Test Types |
|-----------|----------------|------------|
| DSP Utilities | >90% | Unit, numerical accuracy |
| Preprocessing Pipeline | >85% | Unit, integration |
| Each Algorithm | >80% | Unit, accuracy, performance |
| Consensus Engine | >85% | Unit, integration |
| Coordinator | >75% | Integration, timeout handling |

### Performance Benchmarks

**New file**: `test/benchmarks/algorithm_performance_test.dart`

```dart
void main() {
  group('Algorithm Performance Benchmarks', () {
    // Test each algorithm with 5-second signals at various BPMs
    // Measure: execution time, memory usage, accuracy
    // Ensure all algorithms complete within timeout

    test('SimpleOnsetAlgorithm completes in <1s', () { ... });
    test('AutocorrelationAlgorithm completes in <3s', () { ... });
    test('FftSpectrumAlgorithm completes in <2s', () { ... });
    test('WaveletEnergyAlgorithm completes in <5s', () { ... });
    test('Preprocessing pipeline completes in <500ms', () { ... });
  });

  group('Accuracy Benchmarks', () {
    // Test accuracy with various signal types
    for (final bpm in [60, 90, 120, 140, 180]) {
      test('Detects ${bpm} BPM within ±2 BPM', () { ... });
    }
  });
}
```

## Implementation Roadmap

### Phase 1: Foundation (Week 1-2)

**Priority**: High
**Owner**: DSP & Algorithms Engineer

1. **DSP Utilities** (3-4 days)
   - [ ] Implement bandpass filtering
   - [ ] Implement RMS normalization
   - [ ] Add STFT with spectral flux
   - [ ] Create onset envelope utilities
   - [ ] Add unit tests for each utility

2. **Preprocessing Pipeline** (2-3 days)
   - [ ] Create `PreprocessedSignal` data class
   - [ ] Implement `PreprocessingPipeline.process()`
   - [ ] Add integration tests
   - [ ] Profile performance (<500ms target)

3. **Test Infrastructure** (2 days)
   - [ ] Enhance `SignalFactory` with realistic signals
   - [ ] Create synthetic audio fixtures
   - [ ] Set up performance benchmark harness
   - [ ] Document test data organization

### Phase 2: Algorithm Integration (Week 3-4)

**Priority**: High
**Owner**: DSP & Algorithms Engineer + Performance Engineer

4. **Update Algorithm Interface** (1 day)
   - [ ] Modify `BpmDetectionAlgorithm` to accept `PreprocessedSignal`
   - [ ] Update all algorithms to new interface
   - [ ] Ensure backward compatibility during transition

5. **Fix SimpleOnsetAlgorithm** (1 day)
   - [ ] Use pre-computed onset envelope
   - [ ] Add comprehensive unit tests
   - [ ] Verify accuracy maintained or improved

6. **Fix FftSpectrumAlgorithm** (2-3 days)
   - [ ] Replace custom FFT with `fftea` package
   - [ ] Use pre-downsampled 400Hz signal
   - [ ] Test on ARM device (ensure no crash)
   - [ ] Add accuracy tests
   - [ ] Re-enable in algorithm registry

7. **Fix AutocorrelationAlgorithm** (2-3 days)
   - [ ] Use pre-downsampled 8kHz signal
   - [ ] Apply onset envelope weighting
   - [ ] Optimize search range
   - [ ] Verify <3s execution time
   - [ ] Add timeout tests
   - [ ] Re-enable in algorithm registry

8. **Optimize WaveletEnergyAlgorithm** (2-3 days)
   - [ ] Reduce decomposition levels (4 → 2-3)
   - [ ] Simplify candidate selection
   - [ ] Use pre-filtered signal
   - [ ] Target <5s execution
   - [ ] Add performance tests

### Phase 3: Post-Processing & Integration (Week 5)

**Priority**: Medium
**Owner**: DSP & Algorithms Engineer

9. **Enhance Consensus Engine** (2-3 days)
   - [ ] Add beat grid validation
   - [ ] Implement confidence recalibration
   - [ ] Add multi-hypothesis tracking
   - [ ] Generate `RefinedBpmResult` with beat times
   - [ ] Add integration tests

10. **Coordinator Integration** (1-2 days)
    - [ ] Wire preprocessing pipeline into coordinator
    - [ ] Update isolate execution to use preprocessed signals
    - [ ] Verify all algorithms run successfully
    - [ ] Profile end-to-end performance
    - [ ] Test on target Android device

### Phase 4: Testing & Validation (Week 6)

**Priority**: High
**Owner**: Test & QA Engineer

11. **Comprehensive Testing** (3-4 days)
    - [ ] Achieve >85% code coverage
    - [ ] Run performance benchmarks
    - [ ] Test with real audio files
    - [ ] Validate accuracy across BPM range (60-180)
    - [ ] Test edge cases (silence, noise, variable tempo)
    - [ ] Document test results

12. **Integration Testing** (1-2 days)
    - [ ] End-to-end detection with all algorithms enabled
    - [ ] Consensus quality validation
    - [ ] Timeout handling verification
    - [ ] Memory profiling under load
    - [ ] UI responsiveness testing

## Success Criteria

### Functional Requirements

- [ ] All 4 algorithms execute without crashes or timeouts
- [ ] Each algorithm completes within performance budget:
  - SimpleOnset: <1s
  - Autocorrelation: <3s
  - FFT: <2s
  - Wavelet: <5s
- [ ] Preprocessing pipeline: <500ms
- [ ] BPM accuracy: ±2 BPM on synthetic signals (60-180 BPM range)
- [ ] Test coverage: >85% overall

### Performance Requirements

- [ ] End-to-end analysis: <6s (preprocessing + all algorithms + consensus)
- [ ] Memory usage: <50 MB for 10-second audio buffer
- [ ] No UI jank or blocking on main thread
- [ ] Graceful degradation if individual algorithm fails

### Quality Requirements

- [ ] Comprehensive test suite with synthetic and real audio
- [ ] Performance benchmarks pass on target Android hardware
- [ ] Code documentation for all new DSP utilities
- [ ] Architecture diagrams updated in docs

## Risk Assessment

| Risk | Probability | Impact | Mitigation |
|------|------------|--------|------------|
| FFT package still crashes on ARM | Medium | High | Test `fftea` early; have fallback to simpler DFT |
| Preprocessing overhead too high | Low | Medium | Profile early; optimize hotspots; consider caching |
| Autocorrelation still times out | Medium | High | Implement early-exit strategies; reduce max lag range |
| Wavelet remains too slow | Medium | Low | Keep separate scheduling; simplify further if needed |
| Breaking changes to algorithm interface | Low | Medium | Maintain compatibility layer during transition |
| Test fixtures too large for repo | Low | Low | Use compressed formats; generate on-the-fly |

## Future Enhancements (Out of Scope)

- Machine learning-based tempo detection
- Real-time beat tracking with phase-locked loop
- Downbeat detection (measure/bar identification)
- Genre-adaptive algorithm selection
- Time signature detection
- Tempo change detection (accelerando/ritardando)

## References

- `docs/PLAN-01.md`: Original architecture and 10-week roadmap
- `docs/preprocessing.md`: Detailed preprocessing recommendations
- `docs/AGENTS.md`: Agent responsibilities and ownership
- `lib/src/algorithms/`: Current algorithm implementations
- `lib/src/dsp/`: Current DSP utilities

## Appendix A: Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                     Audio Input (Frames)                    │
└─────────────────────────┬───────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│              PHASE 1: PRE-PROCESSING PIPELINE               │
│                                                             │
│  1. Normalization (RMS -18dBFS)                            │
│  2. DC Removal (HPF 20 Hz)                                 │
│  3. Bandpass Filter (20-1500 Hz)                           │
│  4. Onset Envelope (Short-time energy)                     │
│  5. Spectral Flux (STFT frame diff)                        │
│  6. Downsampling (8kHz, 400Hz variants)                    │
│                                                             │
│  Output: PreprocessedSignal                                │
└─────────────────────────┬───────────────────────────────────┘
                          │
              ┌───────────┼───────────┐
              │           │           │
              ▼           ▼           ▼
    ┌─────────────┐ ┌─────────┐ ┌──────────┐
    │   Simple    │ │  Auto-  │ │   FFT    │  ... (Wavelet)
    │   Onset     │ │  corr.  │ │ Spectrum │
    └─────────────┘ └─────────┘ └──────────┘
         │              │            │
         └──────────────┼────────────┘
                        │
                        ▼
              ┌─────────────────┐
              │ BpmReading List │
              └─────────┬───────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│           PHASE 3: POST-PROCESSING & CONSENSUS              │
│                                                             │
│  1. Tempo Normalization (octave correction)                │
│  2. Beat Grid Validation                                   │
│  3. Confidence Recalibration                               │
│  4. Outlier Detection & Removal                            │
│  5. Temporal Smoothing                                     │
│  6. Multi-Hypothesis Tracking                              │
│                                                             │
│  Output: RefinedBpmResult                                  │
└─────────────────────────┬───────────────────────────────────┘
                          │
                          ▼
                   ┌──────────────┐
                   │  UI Display  │
                   │  (BPM + δ)   │
                   └──────────────┘
```

## Appendix B: File Structure After Implementation

```
lib/src/
  dsp/
    preprocessing_pipeline.dart          # NEW
    filtering.dart                       # NEW
    stft.dart                           # NEW
    onset_detection.dart                # NEW
    normalization.dart                  # NEW
    signal_utils.dart                   # ENHANCED
    fft_utils.dart                      # REPLACED (use fftea)
    signal_factory.dart                 # ENHANCED

  algorithms/
    bpm_detection_algorithm.dart        # MODIFIED (new interface)
    simple_onset_algorithm.dart         # MODIFIED (use preprocessing)
    autocorrelation_algorithm.dart      # MODIFIED (optimized)
    fft_spectrum_algorithm.dart         # FIXED (no ARM crash)
    wavelet_energy_algorithm.dart       # OPTIMIZED (faster)
    algorithm_registry.dart             # UNCHANGED
    detection_context.dart              # UNCHANGED

  core/
    bpm_detector_coordinator.dart       # MODIFIED (wire preprocessing)
    consensus_engine.dart               # ENHANCED (post-processing)

test/
  fixtures/audio/...                    # NEW
  dsp/...                               # NEW
  algorithms/...                        # EXPANDED
  core/...                              # EXPANDED
  benchmarks/...                        # NEW
```
