# Future Exploration: Dynamic Programming Beat Tracking

**Status**: Research Note / Future Work
**Priority**: Medium (for musical material accuracy)
**Created**: 2025-10-31

---

## Context

Current BPM detection algorithms use **periodicity detection**:
- Autocorrelation: Find repeating patterns in onset envelope
- FFT: Find dominant frequencies in energy spectrum
- Wavelet: Multi-resolution energy analysis

These work excellently for **steady tempo material** (metronomes: 100% accuracy), but struggle with **expressive music** where tempo varies (rubato, accelerando, ritardando).

---

## Problem Statement

**Musical Material Challenges**:
- Classical piano pieces (poulenc_114, schumann_113): 0% accuracy
- Algorithm disagreement: 40-70 BPM spread
- Root causes:
  - Tempo rubato (expressive timing)
  - Complex rhythmic layers (melody vs accompaniment)
  - Weak/strong beat patterns
  - Harmonic overtones creating false periodicities

**Current Limitation**: Periodicity-based methods assume **constant tempo** over analysis window.

---

## Dynamic Programming Approach

### Core Concept

Instead of finding a single global tempo, **track beat positions** frame-by-frame and allow tempo to vary smoothly.

**Key Idea**: Model tempo as a **path through time** that:
1. Aligns with strong onsets (high cost for missing beats)
2. Changes smoothly (penalty for sudden tempo jumps)
3. Follows musically plausible tempo ranges

### Algorithm Outline

**Input**: Onset strength function O(t) for each time t

**Goal**: Find beat times B = [b₁, b₂, ..., bₙ] that maximize:
```
Score(B) = Σ O(bᵢ) - λ × Σ |Δ(bᵢ) - Δ(bᵢ₋₁)|
           onset alignment    tempo smoothness penalty
```

Where:
- O(bᵢ) = onset strength at beat i
- Δ(bᵢ) = inter-beat interval = bᵢ - bᵢ₋₁
- λ = smoothness parameter

**Dynamic Programming Solution**:
```
D[t, τ] = max score for beat ending at time t with tempo τ
D[t, τ] = O(t) + max_{τ'} (D[t-τ, τ'] - λ|τ - τ'|)
```

**Backtrack** from best final state to recover beat sequence.

### Advantages

1. **Tempo variation**: Naturally handles rubato and tempo changes
2. **Local optimization**: Each beat decision considers local context
3. **Global coherence**: DP ensures globally consistent beat track
4. **Well-studied**: Extensive literature with proven techniques

---

## Literature References

### Foundational Papers

1. **Ellis, D. P. W. (2007)**
   *"Beat Tracking by Dynamic Programming"*
   ISMIR 2007
   - Classic DP beat tracker
   - Onset detection → DP → beat times
   - Tempo transition costs
   - **Implementation**: Relatively straightforward

2. **Davies, M. E. P., & Plumbley, M. D. (2007)**
   *"Context-Dependent Beat Tracking of Musical Audio"*
   IEEE TASLP 15(3)
   - Multi-agent DP system
   - Handles time signature changes
   - Metric level inference (downbeats vs beats)
   - **Complexity**: Moderate

3. **Böck, S., Krebs, F., & Schedl, M. (2016)**
   *"Joint Beat and Downbeat Tracking with Recurrent Neural Networks"*
   ISMIR 2016
   - Modern neural approach (TCN/RNN)
   - State-of-the-art accuracy
   - **Complexity**: High (requires training data)

### Practical Implementations

4. **Madmom Library** (Python)
   - Open-source beat tracking library
   - Includes DP and neural approaches
   - Reference implementation for testing ideas
   - **Link**: https://github.com/CPJKU/madmom

5. **Librosa Beat Tracking** (Python)
   - Ellis DP tracker implementation
   - Good for prototyping
   - **Link**: https://librosa.org/doc/main/generated/librosa.beat.beat_track.html

---

## Implementation Strategy

### Phase 1: Prototype & Validate (Python)

**Goal**: Prove concept on failing test cases

1. **Extract onset function** from preprocessing pipeline
2. **Implement Ellis DP tracker** in Python
3. **Test on poulenc_114.wav and schumann_113.wav**
4. **Measure accuracy** vs current periodicity methods

**Estimated Time**: 1-2 days
**Success Metric**: >50% accuracy on musical fixtures

### Current Progress (2025-11-01)

- ✅ Ported Ellis-style DP tracker to Dart (`DynamicProgrammingBeatTracker`), reusing the shared preprocessing onset envelope.
- ✅ Integrated as an optional algorithm (`dp_beat_tracker`) runnable via the existing isolate pipeline and surfaced in the UI when enabled.
- ✅ Metadata now exposes beat times, intervals, energy ratios, and smoothness for downstream debugging/visualisation.
- 🔄 Next: Tune DP hyperparameters (`lambda`, tempo grid) against classical fixtures and decide on default enablement once accuracy gains are confirmed.

### Phase 2: Dart/Flutter Integration

**Goal**: Production implementation

1. **Port Python prototype** to Dart
2. **Integrate as new algorithm**: `DynamicProgrammingBeatTracker`
3. **Optimize performance** (DP can be slow)
4. **Add to registry** alongside existing algorithms

**Estimated Time**: 2-3 days
**Performance Target**: <500ms for 10s audio

### Phase 3: Hybrid Approach

**Goal**: Combine strengths of both approaches

1. **Periodicity for steady sections**: Use autocorrelation/FFT when tempo stable
2. **DP for expressive sections**: Switch to beat tracking when tempo varies
3. **Tempo variation detection**: Measure onset interval variance
4. **Smart fallback**: Use DP confidence to decide which method to trust

**Estimated Time**: 1-2 days
**Ideal Outcome**: 100% on metronomes, >80% on musical material

---

## Technical Considerations

### Onset Detection Quality

**Critical**: DP is only as good as the onset function.

**Current Status**:
- ✅ Preprocessing generates onset envelope (~100 Hz)
- ✅ Spectral flux with adaptive thresholding
- ⚠️ May need enhancement for piano (weak transients)

**Potential Improvement**:
- Multi-band onset detection (bass, mid, treble separately)
- Logarithmic compression (Tempogram Toolbox approach)
- Adaptive thresholding per frequency band

### Tempo Prior

**Challenge**: Need realistic tempo bounds and transition costs.

**Musical Knowledge**:
- Typical tempo range: 60-180 BPM (but allow 40-240)
- Maximum acceleration: ~10% per beat (human physical limit)
- Time signature hints: 4/4 is most common, affects beat subdivision

**Implementation**:
```dart
// Tempo transition cost
double transitionCost(double tempo1, double tempo2) {
  final ratio = tempo2 / tempo1;
  // Penalize changes > 10%
  return ratio > 1.1 || ratio < 0.91 ? kHighCost : 0.0;
}
```

### Computational Cost

**DP Complexity**: O(T × R²) where:
- T = number of time frames (~1000 for 10s)
- R = tempo range bins (~50 for 60-180 BPM with 2 BPM resolution)

**Total**: ~2.5M operations → feasible on mobile

**Optimization**:
- Sparse tempo grid (coarse → refine)
- Pruning of unlikely paths
- Vectorized operations (if Dart SIMD available)

---

## Expected Outcomes

### Accuracy Improvement

| Material Type | Current (Periodicity) | Expected (DP) |
|---------------|----------------------|---------------|
| Metronomes | 100% | 100% (no regression) |
| Electronic (steady) | ~95% | 95-100% |
| Pop/Rock | ~80% | 85-95% |
| Classical Piano | 0% | **50-80%** |
| Jazz (swing) | Unknown | 40-70% |

### Limitations

**What DP Won't Fix**:
- Polyphonic complexity (multiple simultaneous tempos)
- Extreme rubato (unmeasured, cadenza-like passages)
- Missing beats (rests, fermatas)
- Genre confusion (3/4 vs 6/8 time)

**These require**:
- Music structure analysis
- Harmonic analysis
- Genre classification
- Human-level musical understanding

---

## Decision Criteria

**When to Implement**:
- ✅ Current algorithms achieve 100% on target use cases (metronomes) → **Achieved**
- ✅ Clear evidence that DP would help failing cases → **Yes (classical piano)**
- ✅ User need for musical material support → **To be determined**
- ⚠️ Available development time (5-7 days) → **Consider priority**

**When NOT to Implement**:
- ❌ Target use case is only steady tempo (metronomes, electronic music)
- ❌ Performance requirements too strict (<100ms per detection)
- ❌ Development resources limited

---

## Recommended Next Steps

1. **Validate need**: Confirm users want accuracy on expressive music
2. **Quick prototype**: 1 day Python prototype on poulenc/schumann
3. **Measure improvement**: Compare accuracy quantitatively
4. **Go/No-go decision**: Based on prototype results
5. **If go**: Port to Dart and integrate as optional algorithm

---

## Related Documents

- `docs/algorithms.md` - Current periodicity-based algorithms
- `docs/CONSENSUS-ANALYSIS.md` - Analysis of current failures
- `docs/AUTOCORRELATION-IMPROVEMENTS.md` - Recent algorithm enhancements
- `docs/PLAN-03.md` - Accuracy stabilization roadmap

---

## Status

**Current Decision**: Documented for future exploration. Focus on completing current algorithm improvements and UI work first. Revisit if user feedback indicates strong need for musical material support.

**Next Review**: After completing UI enhancements and gathering user feedback on real-world usage patterns.
