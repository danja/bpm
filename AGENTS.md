# BPM Detection Tool — Core Agents

This document records the long‑lived “agents” (people, automations, or AI assistants) responsible for the Flutter BPM detection project described in `docs/PLAN-01.md`. Each agent name is descriptive so future contributors know who (or what) should own a task area.

## Architecture & Coordination

- **Product & Delivery Lead**  
  - Keeps the 10-week roadmap on track, prioritizes features, tracks risks raised in `docs/PROGRESS.md`.  
  - Decides release scope and coordinates cross-team blockers; signs off on definition of done.

- **Solution Architect**  
  - Owns the layered architecture defined in PLAN-01 (UI → Logic → Algorithms → DSP → Audio I/O).  
  - Reviews major design changes, approves new algorithm integrations, ensures modularity and extensibility.

## Engineering Agents

- **Flutter UI Engineer**  
  - Builds the presentation layer, algorithm selector, waveform visualizations, and loading/error states.  
  - Works closely with the BPM Detector Coordinator to bind streams of BPM updates to widgets.

- **Application Logic Engineer**  
  - Implements the Coordinator, Results Aggregator, and state management (Bloc/Riverpod).  
  - Ensures compute-heavy work stays off the UI thread and that partial results stream correctly.

- **Audio Platform Engineer**  
  - Manages microphone/file input, audio session lifecycle, buffer management, and platform-specific permissions.  
  - Integrates audio plugins (`record`, `just_audio`, etc.) and abstracts them behind a portable interface.

- **DSP & Algorithms Engineer**  
  - Authors the algorithm interface, registry, and implementations (Onset, Autocorrelation, FFT, Wavelet).  
  - Maintains signal preprocessing utilities, validates accuracy targets, and designs consensus weighting.

- **Performance & Reliability Engineer**  
  - Profiles latency/memory, enforces compute isolation (`compute`, isolates, or native FFI helpers).  
  - Owns benchmarking harnesses, synthetic signal generators, and regression alerts for accuracy.

## Quality & Knowledge Agents

- **Test & QA Engineer**  
  - Drives the test pyramid (unit, integration, golden, performance) with >85% coverage goal.  
  - Curates audio fixtures (silence, noise, real songs) and defines acceptance criteria for algorithms.

- **Documentation & Developer Experience**  
  - Maintains README, ARCHITECTURE, ALGORITHMS, TESTING, USER_GUIDE, and agent/progress logs.  
  - Ensures onboarding instructions stay current and captures lessons learned in retrospectives.

## Collaboration Norms

1. Every major milestone/update should append an entry to `docs/PROGRESS.md` with owner + timestamp.  
2. Agents file is the source of truth for responsibilities; update when roles change or new automation is introduced.  
3. When handing off work, note outstanding risks, artifacts, and verification steps in both AGENTS and PROGRESS logs.  
4. Agents must reference PLAN-01 requirements when proposing scope or architectural changes.
