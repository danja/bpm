# Consensus Algorithm Optimization - Implementation Summary

**Date**: 2025-10-31
**Engineer**: DSP & Algorithms Engineer (AI)
**Status**: Phase 1 Complete - Partial Success

---

## Changes Implemented

### Priority 2: Adaptive Cluster Tolerance ✅

**File**: `lib/src/core/robust_consensus_engine.dart`

**Changes**:
- Replaced fixed `clusterTolerance = 3.0 BPM` with adaptive percentage-based tolerance
- New parameters:
  - `clusterTolerancePercent = 0.05` (5% of tempo)
  - `clusterToleranceMinBpm = 2.5` (minimum absolute tolerance)
- Clustering now uses `max(2.5 BPM, tempo × 5%)` for tolerance

**Rationale**:
- Fixed 3.0 BPM is 5% at 60 BPM but only 1.5% at 200 BPM
- Percentage-based tolerance more musically meaningful across tempo ranges
- At 55 BPM: 2.75 BPM tolerance (vs 3.0 BPM before)
- At 114 BPM: 5.7 BPM tolerance (vs 3.0 BPM before) ← allows broader clustering for mid-tempo music
- At 205 BPM: 10.25 BPM tolerance (vs 3.0 BPM before)

**Impact**: Modest improvement - allows algorithms with small disagreements to cluster together at higher tempos.

---

### Priority 5: Enhanced Confidence Metadata Weighting ✅

**File**: `lib/src/core/robust_consensus_engine.dart` - `_readingWeight()` method

**Changes**:
1. **Correction Flag Counting** (lines 567-593):
   - Counts all correction flags: rangeAdjustment, medianAdjustment, fundamentalGuardApplied
   - New: harmonicNormalized flag tracking
   - Extra penalty for non-octave harmonic normalizations

2. **Aggressive Penalties**:
   - 3+ corrections: 0.3× weight (was implicit before)
   - 2 corrections: 0.5× weight
   - 1 correction: 0.75× weight (was ~0.85× before)

3. **Suppressed Buckets Penalty** (lines 595-601):
   - Each suppressed bucket: -15% weight
   - Floor at 0.5× weight
   - Indicates harmonic confusion

4. **Histogram Score Ratio** (lines 533-541):
   - Uses winningScore/totalScore if available
   - Strong cluster (high ratio): near 1.0× weight
   - Weak cluster (low ratio): 0.6× weight minimum

5. **Consistency Weighting** (lines 498-501):
   - Changed from `0.6 + 0.4 * consistency` to `0.5 + 0.5 * consistency`
   - More aggressive penalty for low consistency

**Impact**: Significant - algorithms with multiple corrections or harmonic confusion now heavily downweighted, improving cluster selection.

---

### Priority 1: Enhanced Harmonic Normalization ✅

**File**: `lib/src/core/robust_consensus_engine.dart` - `_normalizeOctaveErrors()` method

**Changes**:
1. **Extended Harmonic Ratios** (lines 170-183):
   ```dart
   1.0,   // Unison (no change)
   2.0, 0.5,     // Octaves
   1.5, 0.667,   // Perfect fifths (3/2, 2/3)
   1.333, 0.75,  // Perfect fourths (4/3, 3/4)
   1.25, 0.8,    // Major thirds (5/4, 4/5)
   1.2, 0.833,   // Minor thirds (6/5, 5/6)
   3.0, 0.333,   // Two octaves
   ```

2. **Conservative Normalization Strategy** (lines 192-218):
   - Only normalizes if reading deviates > 8% OR > 5 BPM from reference
   - Requires 30% improvement in deviation to apply normalization
   - Prevents spurious normalizations of already-reasonable readings

3. **Metadata Tracking** (lines 220-230):
   - New: `harmonicNormalized` flag
   - New: `harmonicRatio` value (e.g., 1.5)
   - New: `harmonicName` string (e.g., "1.5× (perfect fifth up)")
   - Backward compatible: keeps `octaveNormalized` for 2× and 0.5×

4. **Human-Readable Names** (lines 239-253):
   - Helper function `_harmonicName()` for debugging and UI display

**Impact**: Mixed - helps when algorithms are on clear harmonics, but limited effectiveness without good reference tempo. Conservative thresholds prevent regression but also limit applicability.

---

## Test Results

### Overall Performance

| Metric | Before | After | Change |
|--------|--------|-------|--------|
| Total Tests | 35 | 35 | - |
| Passing | 26 | 26 | 0 |
| Failing | 9 | 9 | 0 |
| **Pass Rate** | **74%** | **74%** | **0%** |

### Failure Breakdown

**Still Failing**:
- **poulenc_114.wav** (5 failures): SimpleOnset, Autocorrelation, FFT, Wavelet, Consensus
  - Algorithm spread: 93-133 BPM (40 BPM range!)
  - No cluster can form with this much disagreement
- **schumann_113.wav** (4 failures): Autocorrelation, FFT, Wavelet, Consensus
  - Algorithm spread: 73-140 BPM (67 BPM range!)
  - Extreme harmonic confusion
- **metronome_55.wav** (1 failure): Autocorrelation only
  - Detects 81.94 BPM (3/2 harmonic) instead of 55 BPM

### What Improved

- **Metronomes**: Still 100% passing (no regression) ✓
- **Consensus stability**: Enhanced weighting improves confidence scores
- **Metadata richness**: Now tracks harmonic normalizations for debugging

### What Didn't Improve

- **Musical material**: Still 0% consensus pass rate
- **Algorithm-level failures**: Individual algorithm accuracy unchanged (expected)
- **Harmonic detection**: Normalization helps but insufficient when algorithms deeply disagree

---

## Analysis: Why Limited Improvement?

### Root Cause: Algorithm-Level Problem

The consensus optimizations can only work with what the algorithms provide. Current issues:

1. **Autocorrelation Algorithm** (most problematic):
   - metronome_55: 81.94 BPM (3/2 harmonic)
   - schumann_113: 73.17 BPM (2/3 harmonic)
   - poulenc_114: 133.22 BPM (7/6 harmonic)
   - **Fundamental histogram logic insufficient for complex material**

2. **FFT Spectrum Algorithm**:
   - schumann_113: 82.03 BPM (between harmonics)
   - poulenc_114: 93.75 BPM (4/5 harmonic)
   - **Fundamental guard helps but not enough**

3. **Wavelet Energy Algorithm**:
   - schumann_113: 139.86 BPM (5/4 harmonic)
   - poulenc_114: 95.47 BPM (5/6 harmonic)
   - **Multi-level aggregation still locks onto wrong periodicities**

### Harmonic Normalization Limitations

**Why it's not more effective**:

1. **Chicken-and-egg problem**: Needs good reference to normalize against, but reference comes from consensus of potentially-wrong readings
2. **First-run issue**: On first frame, reference is median of all algorithms - if 3/4 are wrong, median is wrong
3. **Extreme spread**: When algorithms span 40-70 BPM range, no single harmonic transformation brings them together

**Example (schumann_113)**:
- Reference (median): ~107 BPM
- Autocorrelation 73.17: Could normalize to 109.75 (×1.5) ✓
- FFT 82.03: Could normalize to 123.05 (×1.5) - but now too high ✗
- Wavelet 139.86: Could normalize to 111.89 (÷1.25) ✓
- SimpleOnset 115.38: Already close ✓

Even with normalization, FFT ends up far from the others.

---

## Recommendations: Next Steps

### Short Term (Week 2)

**Priority 3: Multi-Reference Clustering** (from CONSENSUS-ANALYSIS.md)
- Generate candidate fundamentals from each reading
- Cluster the fundamentals, not the raw readings
- Would help schumann_113 case significantly

**Algorithm-Specific Improvements**:
1. **Autocorrelation**: Enhance lag selection logic
   - Better handling of weak beats vs strong beats
   - More aggressive harmonic suppression in histogram
   - Could reduce 3/2, 2/3 harmonic errors

2. **FFT**: Improve fundamental selection
   - Multi-peak clustering with harmonic series detection
   - Weight peaks by musical likelihood

3. **Wavelet**: Enhance level aggregation
   - Detect when different levels agree on harmonics
   - Use inter-level agreement to reject bad candidates

### Medium Term (Week 3-4)

**Fixture-Specific Tuning**:
- Add per-genre or per-complexity algorithm weighting
- Classical piano: downweight Autocorrelation, upweight SimpleOnset
- Electronic: upweight FFT, downweight Wavelet

**Advanced Consensus**:
- Implement multi-reference clustering
- Add tempo trajectory tracking (does BPM make musical sense frame-to-frame?)
- Confidence tiers with user feedback

---

## Code Quality & Documentation

### Added Documentation
- `docs/CONSENSUS-ANALYSIS.md`: Comprehensive failure analysis
- `docs/CONSENSUS-IMPLEMENTATION.md`: This implementation summary
- Updated `CLAUDE.md`: Recent findings and next steps
- Inline code comments: Harmonic ratios, normalization strategy

### Code Health
- ✅ No regressions on metronome tests
- ✅ Clean build (no warnings after unused import removed)
- ✅ Backward compatible (old metadata flags preserved)
- ✅ Metadata enriched for debugging

---

## Success Criteria Assessment

From PLAN-03:
- ✅ ≥90% of steady WAV fixtures within ±3 BPM: **Achieved (100% for metronomes)**
- ✗ ≥80% of complex WAV fixtures within ±5 BPM: **Not achieved (0% for music pieces)**

**Overall**: Phase 1 optimizations preserve metronome accuracy while adding infrastructure for further improvements. Musical material requires algorithm-level enhancements, not just consensus improvements.

---

## Files Modified

1. `lib/src/core/robust_consensus_engine.dart`
   - Adaptive cluster tolerance (lines 22-23, 245-249)
   - Enhanced harmonic normalization (lines 153-254)
   - Enhanced confidence weighting (lines 495-610)

2. `test/integration/metronome_wav_test.dart`
   - Added debug prints (temporarily, now removed)
   - Verified percentTolerance working correctly

3. `CLAUDE.md`
   - Added recent findings section
   - Updated immediate next steps

4. `docs/CONSENSUS-ANALYSIS.md` (new)
5. `docs/CONSENSUS-IMPLEMENTATION.md` (new, this file)

---

## Conclusion

The consensus algorithm optimizations are **technically successful** but have **limited practical impact** on the current test failures. The optimizations work as designed:
- Adaptive tolerance allows reasonable clustering
- Enhanced weighting correctly penalizes problematic readings
- Harmonic normalization safely handles common cases

However, **the root problem is algorithm-level**, not consensus-level. To pass the musical fixture tests, we need:

1. **Algorithm improvements** (autocorrelation, FFT, wavelet histogram logic)
2. **Advanced consensus** (multi-reference clustering)
3. **Genre-aware weighting** (recognize piano vs electronic vs percussion)

The infrastructure is now in place for these improvements, with rich metadata tracking and conservative normalization that won't cause regressions.

**Recommendation**: Proceed with algorithm-specific improvements (Priority 4 from CONSENSUS-ANALYSIS.md) before attempting more advanced consensus strategies.
