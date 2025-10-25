# BPM Detection Tool - Comprehensive Development Plan

## Project Overview

A cross-platform mobile BPM (beats per minute) detection tool built in Flutter that runs on iOS and Android. The system implements multiple detection algorithms with a focus on modularity, extensibility, and maintainability.

## Supported Algorithms

1. **Simple Onset Detection** - Energy-based transient detection
2. **Autocorrelation** - Lag-based periodicity detection
3. **FFT-Based** - Frequency domain beat spectrum analysis
4. **Wavelet-Based** - Multi-scale time-frequency analysis using Discrete Wavelet Transform

## Core Architecture

### Architectural Layers

```
┌─────────────────────────────────────────┐
│           UI Layer (Flutter)            │
│  ┌─────────────────────────────────┐   │
│  │  BPM Display | Visualizations   │   │
│  │  Algorithm Selector | Controls  │   │
│  └─────────────────────────────────┘   │
└─────────────────────────────────────────┘
                    │
┌─────────────────────────────────────────┐
│      Application/Business Logic         │
│  ┌─────────────────────────────────┐   │
│  │  BPM Detector Coordinator       │   │
│  │  Audio Session Manager          │   │
│  │  Results Aggregator             │   │
│  └─────────────────────────────────┘   │
└─────────────────────────────────────────┘
                    │
┌─────────────────────────────────────────┐
│      Algorithm Abstraction Layer        │
│  ┌─────────────────────────────────┐   │
│  │  IBPMDetectionAlgorithm         │   │
│  │  AlgorithmRegistry              │   │
│  │  AlgorithmFactory               │   │
│  └─────────────────────────────────┘   │
└─────────────────────────────────────────┘
                    │
┌─────────────────────────────────────────┐
│     Algorithm Implementations           │
│  ┌──────────┐ ┌────────────────────┐   │
│  │ Onset    │ │ Autocorrelation    │   │
│  └──────────┘ └────────────────────┘   │
│  ┌──────────┐ ┌────────────────────┐   │
│  │ FFT      │ │ Wavelet            │   │
│  └──────────┘ └────────────────────┘   │
└─────────────────────────────────────────┘
                    │
┌─────────────────────────────────────────┐
│      DSP Processing Layer               │
│  ┌─────────────────────────────────┐   │
│  │  Signal Preprocessing           │   │
│  │  FFT Engine | Wavelet Transform │   │
│  │  Autocorrelation | Peak Detection│  │
│  │  Filtering | Normalization      │   │
│  └─────────────────────────────────┘   │
└─────────────────────────────────────────┘
                    │
┌─────────────────────────────────────────┐
│      Audio I/O Layer                    │
│  ┌─────────────────────────────────┐   │
│  │  Microphone Input (Platform)    │   │
│  │  File Input (Asset/Picker)      │   │
│  │  Audio Buffer Management        │   │
│  └─────────────────────────────────┘   │
└─────────────────────────────────────────┘
```

### Design Patterns

- **Strategy Pattern**: Algorithm implementations are interchangeable
- **Registry Pattern**: Dynamic algorithm discovery and registration
- **Factory Pattern**: Algorithm instantiation
- **Observer Pattern**: Real-time BPM updates via streams
- **Repository Pattern**: Abstract data access

## Detailed Component Design

### 1. Algorithm Interface

```dart
abstract class IBPMDetectionAlgorithm {
  String get name;
  String get description;
  AlgorithmMetadata get metadata;

  Future<BPMResult> detectBPM(AudioBuffer audio, DetectionParams params);
  Stream<BPMResult> detectBPMRealtime(Stream<AudioBuffer> audioStream);
}
```

**Key Benefits:**
- Easy to add new algorithms
- Algorithms can be tested independently
- Runtime algorithm switching
- Consistent interface across all implementations

### 2. Core Data Models

```dart
class AudioBuffer {
  Float32List samples;      // Raw audio samples
  int sampleRate;           // Sample rate (e.g., 44100 Hz)
  int channels;             // Mono (1) or Stereo (2)
  Duration duration;        // Total duration
}

class BPMResult {
  double bpm;                       // Detected BPM
  double confidence;                // Confidence score (0.0-1.0)
  AlgorithmType algorithm;          // Which algorithm produced this
  DateTime timestamp;               // When detected
  List<BeatTime> beats;            // Individual beat positions
  Map<String, dynamic> metadata;   // Algorithm-specific data
}

class DetectionParams {
  int minBPM;              // Minimum expected BPM (default: 60)
  int maxBPM;              // Maximum expected BPM (default: 200)
  int windowSize;          // Analysis window size in samples
  double sensitivity;      // Detection sensitivity (0.0-1.0)
  Map<String, dynamic> algorithmSpecific;  // Custom params
}
```

### 3. Algorithm Registry

```dart
class AlgorithmRegistry {
  final Map<AlgorithmType, IBPMDetectionAlgorithm> _algorithms = {};

  void register(AlgorithmType type, IBPMDetectionAlgorithm algorithm) {
    _algorithms[type] = algorithm;
  }

  IBPMDetectionAlgorithm get(AlgorithmType type) {
    return _algorithms[type] ?? throw AlgorithmNotFoundException(type);
  }

  List<AlgorithmType> getAvailableAlgorithms() {
    return _algorithms.keys.toList();
  }
}
```

### 4. Algorithm Implementations

#### A. Onset Detection Algorithm

**Approach:**
1. Compute energy envelope (RMS or spectral flux)
2. Apply adaptive thresholding to detect peaks
3. Calculate inter-onset intervals (IOIs)
4. Estimate BPM from median IOI

**Strengths:** Fast, simple, good for percussive music
**Weaknesses:** Sensitive to noise, may miss subtle beats

#### B. Autocorrelation Algorithm

**Approach:**
1. Preprocess audio (apply onset detection function)
2. Compute autocorrelation across different lags
3. Find peaks in autocorrelation function
4. Strongest peak (excluding zero lag) indicates beat period
5. Convert period to BPM

**Strengths:** Robust to noise, finds periodicity well
**Weaknesses:** Computationally intensive, may confuse tempo multiples

#### C. FFT-Based Algorithm

**Approach:**
1. Divide audio into overlapping frames
2. Compute spectral flux (change in spectrum over time)
3. FFT of the onset detection function to find periodicity
4. Peak in beat spectrum indicates tempo
5. Apply harmonic filtering to handle tempo multiples

**Strengths:** Good frequency resolution, handles complex rhythms
**Weaknesses:** Requires longer audio samples, sensitive to windowing

#### D. Wavelet-Based Algorithm

**Approach (per algo-overview.md):**
1. Convert audio to mono and normalize
2. Apply multi-level Discrete Wavelet Transform (DWT)
3. Sum/combine wavelet detail coefficients emphasizing rhythmic peaks
4. Compute autocorrelation on combined wavelet representation
5. Identify lag of highest autocorrelation peak
6. Convert lag to BPM accounting for sample rate
7. Refine using multiple scales

**Strengths:** Excellent time-frequency localization, handles non-stationary signals
**Weaknesses:** Complex implementation, computationally intensive

**Implementation Details:**
- Use Daubechies-4 (db4) wavelet as starting point
- Implement 4-6 decomposition levels
- Focus on detail coefficients at levels 3-5 (rhythmic frequency bands)
- Combine coefficients using weighted sum based on energy

## DSP Processing Utilities

Shared processing components used across algorithms:

### Signal Processing
- **Windowing Functions**: Hamming, Hann, Blackman-Harris
- **Filtering**: Bandpass filters (20Hz-5kHz for rhythm)
- **Normalization**: Peak normalization, RMS normalization
- **Downsampling**: Reduce sample rate for efficiency

### Transforms
- **FFT/IFFT**: Fast Fourier Transform (use `fftea` package)
- **DWT**: Discrete Wavelet Transform (custom implementation)
- **Autocorrelation**: Efficient computation using FFT method

### Feature Extraction
- **Energy Envelope**: RMS, spectral flux
- **Peak Detection**: Adaptive thresholding, local maxima finding
- **Onset Detection Function**: Spectral difference, complex domain

## Project Structure

```
lib/
├── main.dart
├── core/
│   ├── audio/
│   │   ├── audio_buffer.dart
│   │   ├── audio_input_manager.dart
│   │   ├── audio_preprocessor.dart
│   │   └── audio_buffer_pool.dart
│   ├── dsp/
│   │   ├── fft_engine.dart
│   │   ├── wavelet_transform.dart
│   │   ├── autocorrelation.dart
│   │   ├── peak_detector.dart
│   │   ├── windowing.dart
│   │   ├── filters.dart
│   │   └── signal_processing.dart
│   └── models/
│       ├── bpm_result.dart
│       ├── detection_params.dart
│       ├── algorithm_metadata.dart
│       └── beat_time.dart
├── algorithms/
│   ├── base/
│   │   ├── i_bpm_detection_algorithm.dart
│   │   ├── algorithm_registry.dart
│   │   ├── algorithm_factory.dart
│   │   └── algorithm_type.dart
│   ├── onset_detection/
│   │   ├── onset_detection_algorithm.dart
│   │   ├── energy_calculator.dart
│   │   └── onset_detector.dart
│   ├── autocorrelation/
│   │   ├── autocorrelation_algorithm.dart
│   │   └── periodicity_analyzer.dart
│   ├── fft_based/
│   │   ├── fft_based_algorithm.dart
│   │   ├── spectral_flux.dart
│   │   └── beat_spectrum.dart
│   └── wavelet_based/
│       ├── wavelet_based_algorithm.dart
│       ├── dwt_processor.dart
│       ├── daubechies_wavelet.dart
│       └── coefficient_combiner.dart
├── features/
│   └── bpm_detection/
│       ├── presentation/
│       │   ├── bloc/
│       │   │   ├── bpm_detection_bloc.dart
│       │   │   ├── bpm_detection_event.dart
│       │   │   └── bpm_detection_state.dart
│       │   ├── widgets/
│       │   │   ├── bpm_display.dart
│       │   │   ├── waveform_visualizer.dart
│       │   │   ├── algorithm_results_panel.dart
│       │   │   ├── beat_indicator.dart
│       │   │   └── audio_controls.dart
│       │   └── screens/
│       │       ├── bpm_detection_screen.dart
│       │       └── settings_screen.dart
│       ├── domain/
│       │   ├── repositories/
│       │   │   └── bpm_detection_repository.dart
│       │   └── usecases/
│       │       ├── detect_bpm_from_mic.dart
│       │       ├── detect_bpm_from_file.dart
│       │       └── compare_algorithms.dart
│       └── data/
│           └── repositories/
│               └── bpm_detection_repository_impl.dart
├── shared/
│   ├── utils/
│   │   ├── math_utils.dart
│   │   ├── audio_utils.dart
│   │   └── performance_utils.dart
│   ├── constants/
│   │   ├── audio_constants.dart
│   │   └── algorithm_constants.dart
│   └── exceptions/
│       └── audio_exceptions.dart
└── config/
    └── app_config.dart

test/
├── unit/
│   ├── algorithms/
│   │   ├── onset_detection_test.dart
│   │   ├── autocorrelation_test.dart
│   │   ├── fft_based_test.dart
│   │   └── wavelet_based_test.dart
│   ├── dsp/
│   │   ├── fft_engine_test.dart
│   │   ├── wavelet_transform_test.dart
│   │   ├── autocorrelation_test.dart
│   │   ├── peak_detector_test.dart
│   │   └── signal_processing_test.dart
│   ├── core/
│   │   ├── audio_buffer_test.dart
│   │   └── audio_preprocessor_test.dart
│   └── models/
│       └── bpm_result_test.dart
├── integration/
│   ├── audio_pipeline_test.dart
│   ├── algorithm_coordinator_test.dart
│   └── end_to_end_test.dart
├── widget/
│   ├── bpm_display_test.dart
│   └── waveform_visualizer_test.dart
├── fixtures/
│   ├── audio_samples/
│   │   ├── generated/
│   │   │   ├── 60bpm_click.wav
│   │   │   ├── 120bpm_click.wav
│   │   │   ├── 140bpm_click.wav
│   │   │   └── 180bpm_click.wav
│   │   ├── real_audio/
│   │   │   ├── edm_128bpm.wav
│   │   │   ├── rock_140bpm.wav
│   │   │   └── jazz_120bpm.wav
│   │   └── edge_cases/
│   │       ├── tempo_change.wav
│   │       └── polyrhythm.wav
│   ├── expected_results.json
│   └── test_helpers.dart
└── benchmarks/
    ├── algorithm_performance_test.dart
    └── memory_usage_test.dart
```

## Dependencies

### pubspec.yaml

```yaml
name: bpm_detector
description: Multi-algorithm BPM detection for mobile devices
version: 1.0.0

environment:
  sdk: '>=3.0.0 <4.0.0'

dependencies:
  flutter:
    sdk: flutter

  # Audio I/O
  record: ^5.0.0                    # Cross-platform audio recording
  audioplayers: ^5.0.0              # Audio playback
  path_provider: ^2.1.0             # File system paths
  file_picker: ^6.0.0               # File selection
  permission_handler: ^11.0.0       # Microphone permissions

  # DSP & Math
  fftea: ^1.0.0                     # Pure Dart FFT implementation
  ml_linalg: ^13.0.0                # Linear algebra operations

  # State Management
  flutter_bloc: ^8.1.0              # BLoC pattern
  equatable: ^2.0.0                 # Value equality

  # UI Components
  fl_chart: ^0.65.0                 # Waveform visualization

  # Utilities
  intl: ^0.18.0                     # Internationalization
  logger: ^2.0.0                    # Logging

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^3.0.0

  # Testing
  mockito: ^5.4.0                   # Mocking framework
  build_runner: ^2.4.0              # Code generation
  bloc_test: ^9.1.0                 # BLoC testing utilities

  # Integration Testing
  integration_test:
    sdk: flutter

  # Performance
  benchmark_harness: ^2.2.0         # Performance benchmarking
```

## UI/UX Design

### Main Screen Layout

```
┌───────────────────────────────────────┐
│  🎵 BPM Detector                  ⚙️  │
├───────────────────────────────────────┤
│                                       │
│         ┌─────────────────┐          │
│         │   120.5 BPM     │          │
│         │   ♪ ♪ ♪ ♪       │          │
│         └─────────────────┘          │
│                                       │
│  ┌─────────────────────────────────┐ │
│  │  Waveform Visualization         │ │
│  │  [Audio signal with beat marks] │ │
│  │                                  │ │
│  │  ────────▁▄▆█▆▄▁────────        │ │
│  │      ▼   ▼   ▼   ▼   ▼          │ │
│  └─────────────────────────────────┘ │
│                                       │
│  Algorithm Results:                  │
│  ┌─────────────────────────────────┐ │
│  │ ✓ Onset:          118.2 ± 2.1  │ │
│  │ ✓ Autocorrelation: 120.5 ± 1.0 │ │
│  │ ✓ FFT:            121.0 ± 1.5  │ │
│  │ ✓ Wavelet:        119.8 ± 0.8  │ │
│  │                                  │ │
│  │ Consensus: 120 BPM              │ │
│  └─────────────────────────────────┘ │
│                                       │
│  ┌──────────┐  ┌──────────┐         │
│  │ 🎤 Start  │  │ 📁 File  │         │
│  │   Mic    │  │  Input   │         │
│  └──────────┘  └──────────┘         │
└───────────────────────────────────────┘
```

### UI Components

1. **BPM Display Widget**
   - Large, readable BPM number
   - Animated beat indicator (pulsing circle or metronome)
   - Confidence indicator

2. **Waveform Visualizer**
   - Real-time audio waveform
   - Detected beat markers overlaid
   - Scrolling display for continuous audio

3. **Algorithm Results Panel**
   - Expandable list of algorithm results
   - BPM value with confidence/error margin
   - Color-coded by confidence (green=high, yellow=medium, red=low)
   - Consensus BPM (weighted average or median)

4. **Audio Controls**
   - Microphone input button (start/stop)
   - File picker button
   - Settings button (algorithm selection, parameters)

5. **Settings Screen**
   - Enable/disable individual algorithms
   - Adjust detection parameters (min/max BPM, sensitivity)
   - Audio buffer size configuration
   - Export results option

### User Flow

1. User opens app → Main screen with controls visible
2. User taps "Start Mic" OR "File Input"
3. Audio processing begins → Waveform displays
4. Algorithms run in parallel → Results appear as completed
5. Consensus BPM calculated and displayed prominently
6. User can tap individual algorithm results for details
7. User can tap "Stop" to end detection

## Testing Strategy

### 1. Unit Testing

**Test Coverage Requirements:** >85% for algorithm and DSP code

**Algorithm Tests:**
- Test each algorithm with synthetic audio (known BPM)
- Verify BPM detection accuracy within tolerance
- Test edge cases (very slow, very fast tempos)
- Test with varying confidence thresholds

**Example Test:**
```dart
test('OnsetDetection should detect 120 BPM click track', () async {
  // Arrange
  final audio = generateClickTrack(bpm: 120, duration: Duration(seconds: 10));
  final algorithm = OnsetDetectionAlgorithm();
  final params = DetectionParams(minBPM: 60, maxBPM: 200);

  // Act
  final result = await algorithm.detectBPM(audio, params);

  // Assert
  expect(result.bpm, closeTo(120.0, 2.0));  // Within ±2 BPM
  expect(result.confidence, greaterThan(0.8));
});
```

**DSP Tests:**
- FFT correctness (compare with known transforms)
- Wavelet decomposition/reconstruction
- Peak detection accuracy
- Autocorrelation properties

### 2. Integration Testing

**Pipeline Tests:**
- End-to-end audio processing
- Multiple algorithms running concurrently
- Real audio file processing
- Memory management under load

**Example Integration Test:**
```dart
testWidgets('Full detection pipeline with real audio', (tester) async {
  // Load real audio sample
  final audio = await loadAudioFixture('edm_128bpm.wav');

  // Initialize all algorithms
  final registry = AlgorithmRegistry();
  registry.register(AlgorithmType.onset, OnsetDetectionAlgorithm());
  registry.register(AlgorithmType.autocorrelation, AutocorrelationAlgorithm());
  registry.register(AlgorithmType.fft, FFTBasedAlgorithm());
  registry.register(AlgorithmType.wavelet, WaveletBasedAlgorithm());

  // Run detection
  final coordinator = BPMDetectionCoordinator(registry);
  final results = await coordinator.detectWithAllAlgorithms(audio);

  // Verify all algorithms produced results
  expect(results.length, 4);

  // Verify consensus near ground truth (128 BPM)
  final consensus = calculateConsensus(results);
  expect(consensus, closeTo(128.0, 3.0));
});
```

### 3. Widget Testing

- UI component rendering
- User interaction flows
- State updates reflected in UI
- Error state handling

### 4. Test Fixtures

**Synthetic Audio Generation:**
```dart
AudioBuffer generateClickTrack({
  required double bpm,
  required Duration duration,
  int sampleRate = 44100,
}) {
  final samplesPerBeat = (60.0 / bpm * sampleRate).round();
  final totalSamples = (duration.inMicroseconds / 1000000.0 * sampleRate).round();
  final samples = Float32List(totalSamples);

  for (int i = 0; i < totalSamples; i += samplesPerBeat) {
    // Generate click (short impulse)
    for (int j = 0; j < 100 && i + j < totalSamples; j++) {
      samples[i + j] = 1.0 * (1.0 - j / 100.0);  // Decaying impulse
    }
  }

  return AudioBuffer(
    samples: samples,
    sampleRate: sampleRate,
    channels: 1,
    duration: duration,
  );
}
```

**Real Audio Samples:**
- Collect 10-15 audio samples with verified BPM
- Various genres: EDM, rock, hip-hop, jazz, classical
- Tempo range: 60-180 BPM
- Include edge cases: tempo changes, polyrhythms

**Expected Results File (expected_results.json):**
```json
{
  "edm_128bpm.wav": {
    "ground_truth_bpm": 128.0,
    "tolerance": 2.0,
    "expected_algorithms": {
      "onset": {"bpm": 128.0, "min_confidence": 0.85},
      "autocorrelation": {"bpm": 128.0, "min_confidence": 0.90},
      "fft": {"bpm": 128.0, "min_confidence": 0.88},
      "wavelet": {"bpm": 128.0, "min_confidence": 0.92}
    }
  }
}
```

### 5. Performance Benchmarks

**Metrics to Track:**
- Processing time per algorithm
- Memory usage during detection
- Real-time factor (processing time vs. audio duration)
- UI responsiveness (frame rate during processing)

**Benchmark Test:**
```dart
benchmark('Wavelet algorithm performance', () {
  final audio = generateClickTrack(bpm: 120, duration: Duration(seconds: 30));
  final algorithm = WaveletBasedAlgorithm();
  final params = DetectionParams();

  final stopwatch = Stopwatch()..start();
  algorithm.detectBPM(audio, params);
  stopwatch.stop();

  print('Wavelet processing time: ${stopwatch.elapsedMilliseconds}ms');
  expect(stopwatch.elapsedMilliseconds, lessThan(1000));  // < 1 second
});
```

### 6. Continuous Integration

**CI Pipeline (GitHub Actions):**
```yaml
name: CI

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: subosito/flutter-action@v2
      - run: flutter pub get
      - run: flutter analyze
      - run: flutter test --coverage
      - run: flutter test integration_test

  build:
    runs-on: ${{ matrix.os }}
    strategy:
      matrix:
        os: [macos-latest, ubuntu-latest]
    steps:
      - uses: actions/checkout@v3
      - uses: subosito/flutter-action@v2
      - run: flutter build apk  # Android
      - run: flutter build ios --no-codesign  # iOS (macOS only)
```

## Development Phases

### Phase 1: Foundation (Week 1-2)

**Goals:**
- Project scaffolding
- Core infrastructure
- Basic audio I/O

**Tasks:**
1. Create Flutter project with proper structure
2. Add dependencies to pubspec.yaml
3. Implement core data models (AudioBuffer, BPMResult, etc.)
4. Build audio input manager (microphone recording)
5. Implement file loading and playback
6. Create audio buffer pool for memory efficiency
7. Set up testing infrastructure
8. Generate synthetic test audio fixtures
9. Implement basic DSP utilities (windowing, normalization)

**Deliverables:**
- Working Flutter app skeleton
- Audio recording from microphone functional
- Audio file loading functional
- Test fixtures generated
- Unit tests for core models

### Phase 2: DSP Foundation (Week 3)

**Goals:**
- Build shared DSP components
- Validate correctness

**Tasks:**
1. Implement FFT engine (using `fftea` package)
2. Write FFT unit tests (compare with known transforms)
3. Implement basic signal processing functions
4. Build peak detection utility
5. Implement autocorrelation function
6. Create onset detection function (spectral flux)
7. Implement filtering and downsampling
8. Write comprehensive DSP unit tests

**Deliverables:**
- Complete DSP utility library
- Validated FFT implementation
- >90% test coverage for DSP code

### Phase 3: Algorithm Implementation - Part 1 (Week 4)

**Goals:**
- Implement first two algorithms
- Establish algorithm pattern

**Tasks:**
1. Define IBPMDetectionAlgorithm interface
2. Create AlgorithmRegistry and factory
3. Implement OnsetDetectionAlgorithm
   - Energy calculation
   - Peak detection
   - IOI calculation
   - BPM estimation
4. Write unit tests for onset detection
5. Implement AutocorrelationAlgorithm
   - Preprocessing
   - Autocorrelation computation
   - Peak finding
   - Tempo extraction
6. Write unit tests for autocorrelation
7. Test both algorithms with synthetic audio
8. Test both algorithms with real audio samples

**Deliverables:**
- Working onset detection algorithm
- Working autocorrelation algorithm
- Passing unit tests for both
- Validated against known BPM samples

### Phase 4: Algorithm Implementation - Part 2 (Week 5)

**Goals:**
- Implement FFT-based and wavelet algorithms
- Complete algorithm suite

**Tasks:**
1. Implement FFTBasedAlgorithm
   - Frame-based processing
   - Spectral flux calculation
   - Beat spectrum via FFT
   - Peak detection with harmonic filtering
2. Write unit tests for FFT-based algorithm
3. Implement WaveletBasedAlgorithm
   - Daubechies wavelet coefficients
   - Multi-level DWT
   - Coefficient combination
   - Autocorrelation of wavelet representation
   - Tempo estimation and refinement
4. Write unit tests for wavelet algorithm
5. Comparative testing of all four algorithms
6. Parameter tuning for optimal accuracy

**Deliverables:**
- Working FFT-based algorithm
- Working wavelet-based algorithm
- All four algorithms validated
- Performance benchmarks

### Phase 5: Integration Layer (Week 6)

**Goals:**
- Coordinate multiple algorithms
- Build business logic

**Tasks:**
1. Implement BPMDetectionCoordinator
   - Parallel algorithm execution
   - Results aggregation
   - Consensus calculation
2. Build audio session manager
3. Implement real-time processing pipeline
4. Create audio preprocessor
5. Build repository pattern implementation
6. Implement use cases (DetectBPMFromMic, DetectBPMFromFile)
7. Write integration tests
8. Performance optimization (isolates, compute)

**Deliverables:**
- Working multi-algorithm detection
- Real-time processing functional
- Passing integration tests
- Performance targets met (<1s for 30s audio)

### Phase 6: UI Development - Part 1 (Week 7)

**Goals:**
- Build main screen UI
- Implement BLoC state management

**Tasks:**
1. Set up flutter_bloc architecture
2. Define BPMDetectionBloc (events, states)
3. Build main BPM detection screen
4. Implement BPMDisplayWidget
   - Large BPM number
   - Animated beat indicator
   - Confidence display
5. Build audio controls widget
6. Implement algorithm results panel
7. Wire up BLoC to UI
8. Handle loading, success, error states

**Deliverables:**
- Functional main screen
- Working state management
- Basic UI components

### Phase 7: UI Development - Part 2 (Week 8)

**Goals:**
- Advanced UI features
- Polish and UX

**Tasks:**
1. Implement WaveformVisualizer
   - Real-time audio plotting
   - Beat markers overlay
   - Scrolling display
2. Build settings screen
   - Algorithm enable/disable
   - Parameter adjustment
   - Audio configuration
3. Implement error handling UI
4. Add permission handling (microphone)
5. Build loading indicators and animations
6. Implement responsive design
7. Add haptic feedback for beats
8. Write widget tests

**Deliverables:**
- Complete UI with visualizations
- Settings screen functional
- Polished UX
- Widget tests passing

### Phase 8: Cross-Platform Testing (Week 9)

**Goals:**
- Validate iOS and Android
- Fix platform-specific issues

**Tasks:**
1. Test on iOS physical devices
   - Multiple iPhone models
   - Different iOS versions
2. Test on Android physical devices
   - Various manufacturers
   - Different Android versions
3. Test audio input quality and latency
4. Verify permission flows on both platforms
5. Test file picker integration
6. Performance profiling on devices
7. Fix any platform-specific bugs
8. Optimize for different screen sizes

**Deliverables:**
- App working on iOS
- App working on Android
- Platform-specific issues resolved
- Performance acceptable on target devices

### Phase 9: Optimization & Polish (Week 10)

**Goals:**
- Performance optimization
- Final polish
- Documentation

**Tasks:**
1. Profile and optimize hot paths
2. Consider FFI for critical DSP operations if needed
3. Optimize memory usage
4. Reduce app size
5. Add comprehensive error handling
6. Implement logging and diagnostics
7. Create user documentation
8. Write developer documentation
9. Code review and cleanup
10. Final testing pass

**Deliverables:**
- Optimized performance
- Complete documentation
- Production-ready app

### Phase 10: Future Enhancements (Post-Launch)

**Potential Features:**
- Tap tempo input
- BPM history tracking
- Export functionality (CSV, JSON)
- Audio effects preview at detected tempo
- Multiple time signature detection
- Genre classification
- Cloud sync of detection history
- Additional algorithms (neural network-based)

## Performance Optimization Strategies

### 1. Computation Optimization

**Use Isolates for Heavy Work:**
```dart
Future<BPMResult> detectBPM(AudioBuffer audio) async {
  // Run algorithm in separate isolate to avoid UI jank
  return compute(_detectBPMIsolate, audio);
}

static BPMResult _detectBPMIsolate(AudioBuffer audio) {
  // Heavy DSP computation here
  return result;
}
```

**Buffer Pooling:**
- Pre-allocate audio buffers
- Reuse Float32List instances
- Reduce GC pressure

**Optimize Hot Paths:**
- Profile with DevTools
- Optimize inner loops in DSP code
- Consider native code (FFI) for:
  - FFT operations
  - Wavelet transforms
  - Autocorrelation

### 2. Native Code Integration (Optional)

If Dart performance insufficient:

**C++ DSP Library via FFI:**
```cpp
// native/bpm_dsp.h
extern "C" {
  void compute_fft(float* input, int size, float* output);
  void compute_dwt(float* input, int size, int levels, float* output);
}
```

**Dart FFI Bindings:**
```dart
import 'dart:ffi';

typedef ComputeFFTNative = Void Function(Pointer<Float>, Int32, Pointer<Float>);
typedef ComputeFFT = void Function(Pointer<Float>, int, Pointer<Float>);

final dylib = DynamicLibrary.open('libbpm_dsp.so');
final computeFFT = dylib.lookupFunction<ComputeFFTNative, ComputeFFT>('compute_fft');
```

### 3. Memory Optimization

- Stream audio in chunks rather than loading entire file
- Downsample high sample rate audio
- Use appropriate buffer sizes (e.g., 8192 samples)
- Clear old results to prevent memory leaks

### 4. Battery Optimization

- Use lower sample rates when possible (22050 Hz vs 44100 Hz)
- Implement adaptive algorithm selection (simpler algorithms for battery saving)
- Stop processing when app backgrounded
- Use efficient audio format (16-bit PCM)

## Key Implementation Challenges & Solutions

### Challenge 1: Real-time Performance

**Problem:** Processing must keep up with real-time audio input without dropping frames or blocking UI.

**Solutions:**
- Use isolates for all algorithm computations
- Implement ring buffer for incoming audio
- Process in overlapping windows
- Optimize buffer sizes (power of 2)
- Consider downsampling for less critical use cases
- Profile and optimize hot code paths

### Challenge 2: Algorithm Accuracy

**Problem:** Different algorithms may give conflicting results; need robust tempo estimation.

**Solutions:**
- Implement consensus mechanism (weighted average, median, voting)
- Use confidence scores to weight algorithm results
- Detect and correct tempo doubling/halving errors
- Implement tempo tracking for continuously varying tempo
- Post-process results with plausibility checks (e.g., 60-200 BPM range)
- Use multiple scales in wavelet analysis for refinement

### Challenge 3: Wavelet Transform Implementation

**Problem:** No existing Dart library for DWT; complex implementation required.

**Solutions:**
- Start with Daubechies-4 wavelet (simplest useful wavelet)
- Implement forward DWT only (no reconstruction needed)
- Use cascade algorithm for multi-level decomposition
- Pre-compute wavelet filter coefficients
- Optimize for power-of-2 signal lengths
- Validate against reference implementation (e.g., PyWavelets)

**Reference Wavelet Coefficients (Daubechies-4):**
```dart
class Daubechies4Wavelet {
  static const List<double> decompositionLowPass = [
    0.6830127, 1.1830127, 0.3169873, -0.1830127
  ];

  static const List<double> decompositionHighPass = [
    -0.1830127, -0.3169873, 1.1830127, -0.6830127
  ];
}
```

### Challenge 4: Cross-platform Audio I/O

**Problem:** Different audio APIs on iOS and Android; varying latency and quality.

**Solutions:**
- Use `record` package for unified API
- Platform-specific buffer size tuning
  - iOS: smaller buffers for lower latency
  - Android: larger buffers for stability
- Request low-latency audio mode on Android
- Test extensively on both platforms
- Implement fallback for unsupported sample rates

### Challenge 5: Testing DSP Algorithms

**Problem:** Difficult to validate correctness; floating-point precision issues.

**Solutions:**
- Generate synthetic test signals with known properties
- Use epsilon comparisons for floating-point equality
- Compare with reference implementations
- Visual validation tools (plot outputs)
- Statistical validation (mean error, standard deviation)
- Test with edge cases (silence, noise, extreme tempos)

### Challenge 6: UI Responsiveness

**Problem:** Heavy computation can cause UI jank and poor user experience.

**Solutions:**
- Never block UI thread with computation
- Use streams for progressive result updates
- Implement loading indicators
- Show partial results as they become available
- Use `compute()` for all heavy operations
- Profile with Flutter DevTools to identify jank

## Algorithm Accuracy Targets

Based on music information retrieval research, typical accuracy benchmarks:

| Algorithm        | Expected Accuracy | Target Accuracy | Notes                        |
|------------------|-------------------|-----------------|------------------------------|
| Onset Detection  | 70-80%            | 75%             | ±2 BPM tolerance             |
| Autocorrelation  | 75-85%            | 80%             | Best for clear rhythm        |
| FFT-based        | 80-90%            | 85%             | Good for complex music       |
| Wavelet-based    | 85-95%            | 90%             | Best overall, more expensive |
| Consensus        | 90-95%            | 92%             | Weighted combination         |

**Accuracy Measurement:**
- Within ±2 BPM = correct
- Tempo doubling/halving = half credit
- Outside range = incorrect

## Potential Third-Party Libraries

**Consider evaluating:**
- **FFTW (via FFI)**: Industry-standard FFT library (C)
- **KissFFT (via FFI)**: Lightweight FFT library (C)
- **aubio**: Complete audio analysis library (C, has mobile support)
  - Includes onset detection, beat tracking, tempo estimation
  - Well-tested and optimized
  - Could use as reference or via FFI

**Trade-offs:**
- Pure Dart: Easier development, good enough for most cases
- Native (FFI): Better performance, more complex build process

**Recommendation:** Start with pure Dart (`fftea`), add FFI optimization if needed based on performance testing.

## Success Criteria

### Functional Requirements
- ✅ Detects BPM from microphone input
- ✅ Detects BPM from audio files
- ✅ Displays results from all 4 algorithms
- ✅ Shows consensus BPM
- ✅ Visualizes audio waveform with beats
- ✅ Works on iOS and Android

### Performance Requirements
- ✅ Processes 30s audio in <1 second (each algorithm)
- ✅ Real-time processing with <500ms latency
- ✅ No UI jank during processing
- ✅ Memory usage <100MB during operation

### Quality Requirements
- ✅ >85% unit test coverage
- ✅ >90% consensus accuracy (±2 BPM on test set)
- ✅ No crashes or ANR errors
- ✅ Clean architecture (SonarQube/Lint passing)

### User Experience Requirements
- ✅ Intuitive interface (user testing)
- ✅ Responsive feedback (loading indicators)
- ✅ Graceful error handling
- ✅ Smooth animations

## Documentation Deliverables

1. **README.md** - Project overview, setup instructions
2. **ARCHITECTURE.md** - Detailed architecture documentation
3. **ALGORITHMS.md** - Algorithm descriptions and references
4. **API_DOCS.md** - Code API documentation (generated from dartdoc)
5. **TESTING.md** - Testing strategy and test writing guide
6. **CONTRIBUTING.md** - Contribution guidelines
7. **USER_GUIDE.md** - End-user documentation

## References

### Academic Papers
- Tzanetakis et al. (2001) "Audio Analysis using the Discrete Wavelet Transform"
- Dixon, S. (2007) "Evaluation of the Audio Beat Tracking System BeatRoot"
- Scheirer, E. (1998) "Tempo and Beat Analysis of Acoustic Musical Signals"

### Libraries & Tools
- Flutter: https://flutter.dev
- fftea: https://pub.dev/packages/fftea
- record: https://pub.dev/packages/record
- flutter_bloc: https://pub.dev/packages/flutter_bloc

### Wavelet Resources
- PyWavelets documentation (for validation)
- "A Wavelet Tour of Signal Processing" by Mallat

## Conclusion

This plan provides a comprehensive roadmap for building a production-quality BPM detection tool with:

1. **Strong Modularity** - Clear separation of concerns, easy to extend with new algorithms
2. **Multiple Algorithms** - Four distinct approaches with comparative results
3. **Comprehensive Testing** - Unit, integration, and performance testing with >85% coverage
4. **Cross-Platform Support** - Native iOS and Android implementation
5. **Production-Ready** - Performance optimization, error handling, user-friendly UI

The 10-week development timeline is realistic for a team of 2-3 developers or a single experienced developer. Each phase builds on the previous, allowing for iterative development and early validation of core functionality.

The architecture is designed for long-term maintenance and extensibility, making it easy to add new algorithms, improve existing ones, or extend functionality in the future.
