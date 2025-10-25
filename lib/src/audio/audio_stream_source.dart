import 'package:bpm/src/models/bpm_models.dart';

class AudioStreamConfig {
  const AudioStreamConfig({
    this.sampleRate = 44100,
    this.channels = 1,
    this.frameDuration = const Duration(milliseconds: 2048),
  });

  final int sampleRate;
  final int channels;
  final Duration frameDuration;
}

abstract class AudioStreamSource {
  Future<void> start(AudioStreamConfig config);
  Future<void> stop();
  Stream<AudioFrame> frames(AudioStreamConfig config);
}
