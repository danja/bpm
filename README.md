# BPM Detection Tool

Real-time Flutter application that captures microphone audio, runs multiple BPM detection algorithms (onset energy + autocorrelation to start), and surfaces both individual and consensus tempo estimates. The architecture follows the layered approach defined in `docs/PLAN-01.md`.

## Getting Started

1. Install Flutter 3.13+ and enable iOS/Android tooling.
2. From the repo root, run `flutter pub get`.
3. Launch the app with `flutter run` (enable microphone permissions).

Key docs:

- `AGENTS.md` – ownership map.
- `docs/PLAN-01.md` – master implementation plan.
- `docs/PROGRESS.md` – milestone log.
