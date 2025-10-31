# PLAN-03: Accuracy Stabilization & Validation Roadmap

**Document Owner**: DSP & Algorithms Engineer + QA Engineer
**Created**: 2025-10-30
**Status**: In Progress (Week 1 refinement underway)
**Purpose**: Define the next major iteration focused on delivering reliable BPM accuracy across algorithms, consensus, and real-world fixtures.

---

## 1. Objectives

- **Restore ground-truth accuracy**: Ensure every enabled detector converges to the true tempo within ±3 BPM for steady signals (nightly CI), and within ±5 BPM for noisy/complex material (manual validation set).
- **Prevent half/double tempo drift**: Harden the pipeline against harmonic misclassification via interval filtering, harmonic-aware clustering, and consensus safeguards.
- **Establish repeatable validation**: Stand up automated tests on WAV fixtures covering steady, dynamic, and genre-diverse material, with trend tracking across branches.
- **Instrument confidence semantics**: Align per-algorithm and consensus confidence outputs with real stability so the UI can surface trustworthy readings.

---

## 2. Current Pain Points

1. **Simple Onset algorithm** relies on raw inter-peak intervals, causing dominant half-beat clusters; lacks robustness to choose fundamental tempo.
2. **Autocorrelation/FFT/Wavelet** still occasionally emit harmonics, but tests don’t assert real WAV fixture behavior.
3. **Consensus engine** treats all algorithm readings equally even when metadata hints at harmonic mismatch.
4. **Confidence metrics** remain loosely tied to actual accuracy, leading to false sense of reliability in the UI.
5. **Validation coverage** limited to synthetic signals, leaving real audio regressions undetected until manual testing.

---

## 3. Strategy Overview

### Phase A — Interval & Harmonic Refinement (Week 1)

**Progress so far (2025-10-30)**

- ✅ Added histogram-based fundamental selector for `SimpleOnsetAlgorithm` with duration-weighted bins and harmonic penalties.
- ✅ Expanded per-reading metadata (bucket scores, multipliers, supporter counts) surfaced to consensus and integration tests.
- ⏳ Remaining: propagate the same histogram weighting to Autocorrelation (initial lag histogram landed), retune penalties via WAV fixtures, and finalise adaptive threshold tuning.
- 🔍 **New insight (Tempogram Toolbox)**: plan to integrate a bandwise spectral-flux novelty curve with logarithmic compression and adaptive differentiation (cf. `audio_to_noveltyCurve.m`) to strengthen onset detection on weak-transient material.

1. **Interval histogramming**
   - Build histograms over inter-onset intervals (quantized bins) to identify dominant periodicities.
   - Filter intervals by selecting the highest-energy fundamental bucket and optionally its neighbors.
   - Weight intervals by duration and amplitude, not just count, to favor full-beat spacing.

2. **Harmonic penalty tuning**
   - Apply stronger penalties for multipliers > 1 when a near-1× candidate exists within tolerance.
   - Track harmonic adjustments in metadata so consensus can down-weight readings that relied on heavy correction.

3. **Algorithm-specific tweaks**
   - Simple Onset: adopt histogram-based fundamental resolver; introduce adaptive thresholding for varying dynamics.
   - Autocorrelation: use histogram-driven lag selection; combine with onset-weighted envelope to bias toward fundamental tempo.
   - FFT Spectrum: consider multi-peak clustering (harmonic series detection) to identify fundamental frequency.
   - Wavelet: integrate envelope consistency checks and avoid aggregating bands that reinforce 2× tempo.

### Phase B — Consensus Intelligence (Week 2)

1. **Metadata-weighted consensus scoring**
   - Combine cluster consistency, harmonic multiplier deviations, and correction flags to compute per-reading reliability.
   - Introduce rules penalizing consensus if algorithms are split across harmonic families (e.g., some at ~½, some at ~2× fundamental).
   - Incorporate novel pulse cues: feed predominant local pulse (PLP) curves from a tempogram (`tempogram_to_PLPcurve.m`) as an auxiliary consensus source.

2. **Confidence semantics refresh**
   - Map confidence into qualitative tiers (High/Medium/Low) using empirical thresholds derived from validation runs.
   - Surface reasons for low confidence in metadata (e.g., “harmonic disagreement”, “low agreement across algorithms”).

### Phase C — Validation & Tooling (Week 3)

1. **WAV fixture suite**
   - Curate fixtures: steady metronome (60–180 BPM), live drum loop, electronic track with syncopation, tempo ramp, noise-heavy clip.
   - Extend integration tests to cover each algorithm + consensus on all fixtures, with per-fixture tolerances.
   - Add CLI harness (`tool/bpm_wav_regression.dart`) to batch-run fixtures, report deltas vs. baselines, and log novelty/PLP diagnostics for analysis.

2. **CI & reporting**
   - Integrate fixtures into CI with caching (e.g., storing WAVs in git LFS or artifact bucket).
   - Generate JSON/Markdown report summarizing per-algorithm deltas and confidence levels.

### Phase D — UX & Observability (Week 4)

1. **UI feedback loop**
   - Display consensus confidence tier and highlight when harmonic corrections were applied (e.g., icon or text).
   - Offer optional per-algorithm details to help users see which detectors agree.

2. **Telemetry hooks**
   - Instrument optional logging (flag-protected) capturing reading metadata for field debugging.
   - Collect aggregate stats (mean ± std diff from ground truth) during manual QA runs.

---

## 4. Deliverables & Milestones

| Week | Deliverable | Owner(s) |
| ---- | ----------- | -------- |
| 1 | Interval histogram module, onset/autocorr refinements, unit tests on synthetic data | DSP Engineer |
| 2 | Consensus scoring updates, metadata-driven weighting, confidence redesign | DSP Engineer + Core Engineer |
| 3 | WAV fixture suite (5+ clips), integration tests, batch regression harness | QA Engineer + DSP Engineer |
| 4 | UI confidence indicators, optional telemetry, documentation update | Flutter UI Engineer + Documentation |

Each milestone should conclude with a regression run on both synthetic and WAV fixtures, logging results in `docs/PROGRESS.md` and attaching the report artifact.

---

## 5. Risks & Mitigations

| Risk | Impact | Mitigation |
| ---- | ------ | ---------- |
| Interval histogram misidentifies beat (e.g., polyrhythms) | Wrong tempo despite refinements | Add fallback heuristics (e.g., favor longest consistent period) and multi-modal detection |
| Increased compute from histogram/clustering | UI lag or timeout | Profile algorithms; cache preprocessing results; optimize loops; consider isolates |
| Fixture licensing/size | CI blocking commits | Use CC-licensed or self-recorded samples; store via LFS; document sourcing |
| Confidence thresholds misaligned | User confusion | Calibrate using validation suite; iterate with QA feedback |

---

## 6. Success Criteria & Metrics

- **Accuracy**: ≥90 % of WAV fixtures within ±3 BPM for steady signals; ≥80 % within ±5 BPM for complex signals.
- **Confidence calibration**: High-confidence readings correspond to ≤3 BPM error 95 % of the time (tracked in validation suite).
- **Stability**: No algorithm produces sustained double/half tempo on steady clips under standard device conditions.
- **Regression coverage**: `flutter test` + WAV suite pass in CI with <3 min runtime overhead.
- **Documentation**: `docs/PLAN-03.md`, `docs/linux-wav-test-rig.md`, and README sections updated with new validation steps.

---

## 7. Next Actions (Week 1 Kick-off)

1. Prototype interval histogram module for Simple Onset using existing synthetic tests.
2. Create additional unit tests targeting histogram edge cases (e.g., alternating strong/weak beats).
3. Draft WAV fixture list and secure licensing; script downloads into `assets/audio/fixtures`.
4. Schedule check-in midway through Week 1 to review histogram outputs and adjust harmonic penalties based on early results.
