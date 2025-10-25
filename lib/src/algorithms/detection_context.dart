class DetectionContext {
  const DetectionContext({
    required this.sampleRate,
    required this.minBpm,
    required this.maxBpm,
    required this.windowDuration,
  });

  final int sampleRate;
  final double minBpm;
  final double maxBpm;
  final Duration windowDuration;
}
