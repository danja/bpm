# Consensus Algorithm Analysis & Optimization Plan

**Date**: 2025-10-31
**Context**: Analysis of test failures and consensus algorithm performance on WAV fixtures

---

## Test Failure Summary

### Overall Status
- **Total Tests**: 35 (7 fixtures × 5 tests each)
- **Passed**: 26
- **Failed**: 9
- **Pass Rate**: 74%

### Failure Breakdown by Algorithm

| Algorithm | Metronome Tests | Music Tests | Total Failures |
|-----------|----------------|-------------|----------------|
| SimpleOnset | 0/5 | 1/2 | 1 |
| Autocorrelation | 1/5 | 2/2 | 3 |
| FFT Spectrum | 0/5 | 2/2 | 2 |
| Wavelet Energy | 0/5 | 1/2 | 1 |
| Consensus | 0/5 | 2/2 | 2 |

**Key Finding**: All algorithms perform well on metronomes but struggle with real musical material (classical piano pieces).

---

## Detailed Failure Analysis

### 1. metronome_55.wav (55 BPM)

| Algorithm | Detected BPM | Error | Harmonic Analysis |
|-----------|-------------|-------|-------------------|
| SimpleOnset | 54.55 | -0.45 | ✓ Correct |
| **Autocorrelation** | **81.94** | **+26.94** | ✗ 3/2 harmonic (55 × 1.49 = 82) |
| FFT | 58.59 | +3.59 | ✓ Close |
| Wavelet | 44.22 | -10.78 | ~ 4/5 harmonic (55 × 0.80 = 44) |

**Consensus**: Passed (within ±2.5 BPM tolerance)

**Issue**: Autocorrelation locked onto 3/2 harmonic. This is a **triplet/swing rhythm confusion** where the algorithm detects the subdivisions instead of the main beat.

---

### 2. poulenc_114.wav (114 BPM - Classical Piano)

| Algorithm | Detected BPM | Error | Harmonic Analysis |
|-----------|-------------|-------|-------------------|
| **SimpleOnset** | **107.14** | **-6.86** | ~ 15/16 (slightly low) |
| **Autocorrelation** | **133.22** | **+19.22** | ✗ 7/6 harmonic (114 × 1.17 = 133) |
| **FFT** | **93.75** | **-20.25** | ✗ 4/5 harmonic (114 × 0.82 = 93.5) |
| Wavelet | 95.47 | -18.53 | ~ 5/6 harmonic (114 × 0.84 = 95.8) |

**Consensus**: Failed

**Issue**: Algorithm scatter across multiple harmonic families:
- SimpleOnset: Near fundamental (~94% of expected)
- Autocorrelation: +17% (faster harmonic)
- FFT & Wavelet: -18% (slower harmonic cluster)

With cluster tolerance of 3.0 BPM, FFT/Wavelet form a cluster around 94-95 BPM, which gets selected as consensus. But this is the **wrong** cluster.

---

### 3. schumann_113.wav (113 BPM - Classical Piano)

| Algorithm | Detected BPM | Error | Harmonic Analysis |
|-----------|-------------|-------|-------------------|
| SimpleOnset | 115.38 | +2.38 | ✓ Close to fundamental |
| **Autocorrelation** | **73.17** | **-39.83** | ✗ 2/3 harmonic (113 × 0.65 = 73) |
| **FFT** | **82.03** | **-30.97** | ✗ Mixed harmonic |
| **Wavelet** | **139.86** | **+26.86** | ✗ 5/4 harmonic (113 × 1.24 = 140) |

**Consensus**: Failed

**Issue**: Extreme algorithm disagreement:
- SimpleOnset: Correct (~102%)
- Autocorrelation: 2/3 harmonic (65%)
- FFT: ~73% (between 2/3 and 3/4)
- Wavelet: 5/4 harmonic (124%)

**This is the worst case**: Every algorithm latches onto a different harmonic. No meaningful cluster can form.

---

## Root Cause Analysis

### 1. Harmonic Detection Gaps

**Current State** (`RobustConsensusEngine.dart:151-195`):
- Only normalizes **octave errors** (2× and 0.5×)
- Does not handle common musical harmonics:
  - 3/2 (perfect fifth - very common in music)
  - 2/3 (subharmonic)
  - 4/5, 5/4 (major third intervals)
  - 7/6, 6/7 (minor thirds)

**Evidence**:
```dart
// Line 168-173: Only handles 2× and 0.5×
final ratio = bpm / _previousBpm!;
if ((ratio - 0.5).abs() <= halfTempoTolerance) {
  bpm *= 2;
} else if ((ratio - 2).abs() <= halfTempoTolerance) {
  bpm /= 2;
}
```

### 2. Clustering Too Rigid

**Current State** (`clusterTolerance = 3.0 BPM`):
- Fixed 3.0 BPM tolerance works for metronomes
- Fails when real music spreads algorithms across 40+ BPM range
- No adaptive tolerance based on tempo (3 BPM is 5% at 60 BPM but only 1.5% at 200 BPM)

### 3. Missing Cross-Algorithm Harmonic Reasoning

**Current Gap**: No mechanism to detect when algorithms form harmonic families.

**Example** (poulenc_114):
- FFT (93.75) and Wavelet (95.47) cluster together
- But both are **wrong harmonics** of 114 BPM
- SimpleOnset (107.14) is closer to truth but excluded from cluster
- Autocorrelation (133.22) is also excluded

**What's needed**: Detect that 93.75 × 1.22 ≈ 114 and 95.47 × 1.19 ≈ 114, then infer the fundamental.

### 4. No Musical Context Awareness

Real music has characteristics that metronomes lack:
- **Tempo variation** (rubato, accelerando, ritardando)
- **Complex rhythmic layers** (melody vs accompaniment)
- **Harmonic overtones** from multiple instruments
- **Weak/strong beats** (not all beats are equally accented)

Classical piano particularly challenging:
- Rich harmonic content
- Varying dynamics
- Expressive timing

---

## Optimization Recommendations

### Priority 1: Enhanced Harmonic Normalization

**Goal**: Detect and normalize common musical harmonics beyond just octaves.

**Implementation**:
```dart
// Expand _normalizeOctaveErrors to handle common harmonics
final commonHarmonics = [
  2.0,   // Octave up
  0.5,   // Octave down
  1.5,   // Perfect fifth (3/2)
  0.667, // Perfect fourth down (2/3)
  1.333, // Perfect fourth up (4/3)
  0.75,  // Minor third down (3/4)
  1.25,  // Major third up (5/4)
  0.8,   // (4/5)
  1.2,   // (6/5)
];

// For each reading, test against reference with all harmonics
// Choose the normalization that brings it closest to reference
```

**Expected Impact**:
- metronome_55: Autocorrelation's 81.94 → normalized to 54.6 (÷ 1.5)
- schumann_113: Autocorrelation's 73.17 → normalized to 109.75 (× 1.5)
- schumann_113: Wavelet's 139.86 → normalized to 111.89 (÷ 1.25)

### Priority 2: Adaptive Cluster Tolerance

**Goal**: Use tempo-proportional clustering instead of fixed BPM threshold.

**Implementation**:
```dart
// Instead of: clusterTolerance = 3.0
// Use percentage-based:
final tolerance = anchor.bpm * clusterTolerancePercent; // e.g., 0.05 = 5%
```

**Rationale**:
- 3 BPM at 60 BPM = 5% deviation (reasonable)
- 3 BPM at 200 BPM = 1.5% deviation (too strict)
- 5% tolerance is more musically meaningful across tempo ranges

### Priority 3: Multi-Reference Clustering

**Goal**: When no clear cluster emerges, test if algorithms represent harmonic multiples of a fundamental.

**Algorithm**:
1. If best cluster has <50% of total weight, activate multi-reference mode
2. Generate candidate fundamentals from each reading:
   - For each reading, compute potential fundamentals by dividing/multiplying by common harmonics
3. Cluster these candidate fundamentals
4. Select the fundamental with most supporting evidence
5. Normalize all readings to that fundamental

**Example** (schumann_113):
```
SimpleOnset: 115.38 → candidates [115.38, 76.92, 173.07, ...]
Autocorrelation: 73.17 → candidates [73.17, 109.75 (×1.5), 146.34 (×2), ...]
FFT: 82.03 → candidates [82.03, 123.05 (×1.5), ...]
Wavelet: 139.86 → candidates [139.86, 111.89 (÷1.25), 93.24 (÷1.5), ...]

Cluster candidate fundamentals:
- ~113 BPM: [115.38, 109.75, 111.89] → 3 supporters
- ~73 BPM: [73.17] → 1 supporter
- ~82 BPM: [82.03] → 1 supporter

Winner: ~113 BPM cluster
Consensus: mean(115.38, 109.75, 111.89) = 112.3 BPM ✓
```

### Priority 4: Algorithm Reliability Scoring

**Goal**: Weight algorithms based on their historical accuracy on musical vs metronome material.

**Observation**:
- Autocorrelation: 1/5 failures on metronomes, 2/2 failures on music → **unreliable on complex material**
- SimpleOnset: 0/5 failures on metronomes, 1/2 on music (and that was close) → **most reliable**
- Wavelet: 0/5 on metronomes, 1/2 on music → **good**

**Implementation**:
```dart
// Add dynamic weighting based on signal complexity
final complexity = _estimateSignalComplexity(signal);
// Higher complexity → downweight autocorrelation, upweight onset

// Track per-algorithm success rate
// Reduce weight for algorithms with high error variance
```

### Priority 5: Confidence Metadata Integration

**Goal**: Use existing metadata from algorithms to inform consensus.

**Current Metadata** (from algorithms):
- `clusterConsistency`: How well intervals clustered
- `rangeMultiplier`: Whether normalization was needed
- `suppressedBuckets`: How many harmonic candidates were rejected
- `fundamentalGuardApplied`: FFT applied fundamental guard

**Observation**: Algorithms already know when they're uncertain!
- schumann wavelet: likely has low `clusterConsistency`
- poulenc autocorrelation: likely has high `suppressedBuckets`

**Enhancement**:
- More aggressively downweight readings with:
  - `rangeMultiplier` far from 1.0
  - Low `clusterConsistency`
  - High `suppressedBuckets` count
  - Multiple correction flags

---

## Implementation Priority

1. **Week 1** (High Impact, Low Complexity):
   - ✅ Priority 2: Adaptive cluster tolerance (1-2 hours)
   - ✅ Priority 5: Enhanced confidence metadata weighting (2-3 hours)

2. **Week 2** (High Impact, Medium Complexity):
   - ✅ Priority 1: Enhanced harmonic normalization (4-6 hours)
   - Test on all fixtures, measure improvement

3. **Week 3** (Medium Impact, High Complexity):
   - ⚠ Priority 3: Multi-reference clustering (6-8 hours)
   - Advanced algorithm, needs careful testing

4. **Week 4** (Refinement):
   - Priority 4: Algorithm reliability scoring
   - Performance profiling and optimization
   - Documentation updates

---

## Success Metrics

**Target** (PLAN-03 Week 2 goals):
- ≥90% of steady WAV fixtures within ±3 BPM
- ≥80% of complex WAV fixtures within ±5 BPM

**Current Performance**:
- Metronomes: 100% within ±3 BPM ✓
- Music: 0% within ±5 BPM (both failed) ✗

**Expected After Optimizations**:
- Priority 1+2 should fix schumann_113 (bring all algorithms to ~113 cluster)
- Priority 1+2+5 should fix poulenc_114 (upweight SimpleOnset, downweight bad harmonics)
- Stretch: Multi-reference clustering handles edge cases

---

## Testing Strategy

1. **Keep existing debug prints** during optimization phase
2. **Add new fixtures**: More musical material (different genres, tempos, time signatures)
3. **Track consensus decisions**: Log which cluster won and why
4. **A/B testing**: Run old vs new consensus engine on same fixtures
5. **Regression prevention**: Ensure metronome performance doesn't degrade

---

## Related Documents

- `lib/src/core/robust_consensus_engine.dart` - Current implementation
- `docs/PLAN-03.md` - Week 2 consensus intelligence roadmap
- `test/integration/metronome_wav_test.dart` - Test harness
- `docs/algorithms.md` - Algorithm descriptions and references
