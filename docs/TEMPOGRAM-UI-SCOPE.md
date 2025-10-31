# Tempogram UI Replacement Scope

**Owner**: Flutter UI Engineer + DSP & Algorithms Engineer  
**Last Updated**: 2025-10-30

## Goals

- Replace the current oscilloscope widget with an interactive tempogram view derived from the preprocessing pipeline.
- Mirror the analytics available in `visualize_tempogram.m` from the MATLAB Tempogram Toolbox while fitting Flutter architecture and performance constraints.
- Provide users with an intuitive visualisation of dominant tempo bands, recent consensus history, and per-algorithm cues.

## MATLAB Reference Summary

`visualize_tempogram.m` renders:
1. A novel feature curve (e.g., onset strength).
2. A tempogram heatmap in tempo (BPM) × time.
3. Overlaid predominant local pulse (PLP) curves / peak tracks.
4. Optional annotations for ground-truth tempo or algorithm estimates.

Key mechanics to translate:
- Compute tempogram via ACF/DFT over novelty curve windows (10–20 s history, 50–250 BPM).
- Normalise and colour-map the tempogram for clarity at multiple dynamic ranges.
- Extract predominant tempo trajectories to overlay on the heatmap.

## Proposed Flutter Architecture

### Data Path

1. **Preprocessing Pipeline**
   - Extend `PreprocessedSignal` to include a tempogram matrix + BPM axis.
   - Reuse existing novelty curve (`NoveltyComputer`) and STFT utilities to generate the tempogram in isolates.
   - Export PLP tracks (dominant BPM per frame) for overlay.

2. **State Management**
   - Update `BpmDetectorCoordinator` to emit tempogram snapshots alongside detector readings.
   - Add an optional history buffer (e.g., 8–10 windows) to animate recent progression.

3. **UI Layer**
   - Build a dedicated `TempogramView` widget (CustomPainter or `Canvas`-based) rendering:
     - Heatmap (tempo on vertical axis, time horizontal).
     - Overlay polylines for PLP / consensus tempo.
     - Per-algorithm markers (colour-coded) updated each cycle.
   - Provide pinch/drag interactions to zoom tempo range or scrub time.

### Rendering Considerations

- Heatmap Resolution: Aim for ≤256 × 128 samples per view (post-resampling) to balance fidelity & performance.
- Colour Map: Implement a perceptually uniform palette (e.g., Turbo/Viridis) in Dart for consistency.
- Accessibility: include optional high-contrast theme and tooltips for tempo/value readouts.
- Animation Budget: target ≤4 ms paint time on mid-range Android devices—use shader caches and reuse `Picture` objects when possible.

### Integration Tasks

1. **DSP Backend**
   - [ ] Implement `TempogramComputer` (ACF + DFT modes) using novelty curve; expose to preprocessing pipeline.
   - [ ] Calculate PLP curve and confidence, aligning with MATLAB reference.
   - [ ] Add throttling so tempogram recomputes at a lower cadence (e.g., every second) to save CPU.

2. **Coordinator Enhancements**
   - [ ] Extend models/events to carry `TempogramSnapshot` (matrix, axes, overlays, timestamps).
   - [ ] Add caching & lifecycle (clear on stop, accumulate on resume).

3. **Flutter UI**
   - [ ] Build `TempogramView` painter with heatmap, overlays, and interactive controls.
   - [ ] Update detection screen layout to host the new widget, ensuring responsiveness on phone & tablet breakpoints.
   - [ ] Add legends / toggle controls for algorithms, PLP, and consensus overlays.

4. **Testing & Validation**
   - [ ] Unit-test tempogram generation vs. MATLAB baseline (sample WAVs).
   - [ ] Golden tests for the painter using deterministic tempogram fixtures.
   - [ ] Integration test: drive preprocessing pipeline on sample audio, assert snapshot fields.

## Acceptance Criteria

- Tempogram view renders within 200 ms (cold) / 16 ms (warm) on target Android hardware.
- Detected consensus tempo curve aligns with metronome fixtures within ±3 BPM in the overlay.
- Users can toggle algorithm traces and zoom the tempo range without UI jank.
- Legacy oscilloscope widget is removed; documentation and onboarding updated accordingly.

## Open Questions

- Source of colour map assets (precomputed LUT vs. runtime generation).
- Whether to expose tempogram snapshots via diagnostics API for QA export.
- How to handle high-latency devices—might require adaptive resolution.

## Dependencies

- Completion of PLAN-03 Phase A (algorithm accuracy) — ✅.
- Confidence semantics refresh (Phase B) to ensure overlays reflect trust levels.
- Potential additional isolate budget for tempogram calculation (profile once implemented).
