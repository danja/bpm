import 'dart:async';
import 'dart:typed_data';

import 'package:bpm/src/audio/audio_stream_source.dart';
import 'package:bpm/src/dsp/pcm_utils.dart';
import 'package:bpm/src/models/bpm_models.dart';
import 'package:record/record.dart';

class RecordAudioStreamSource implements AudioStreamSource {
  RecordAudioStreamSource({Record? record}) : _record = record ?? Record();

  final Record _record;
  StreamController<AudioFrame>? _controller;
  StreamSubscription<Uint8List>? _recordSub;
  int _sequence = 0;

  @override
  Future<void> start(AudioStreamConfig config) async {
    if (_controller != null) {
      return;
    }

    if (!await _record.hasPermission()) {
      throw Exception('Microphone permission not granted');
    }

    final stream = await _record.startStream(
      encoder: AudioEncoder.pcm16bit,
      bitRate: config.sampleRate * 16,
      samplingRate: config.sampleRate,
    );

    _controller = StreamController<AudioFrame>.broadcast(
      onCancel: () => stop(),
    );

    _recordSub = stream.listen((chunk) {
      final samples = PcmUtils.bytesToFloat32(
        chunk,
        channels: config.channels,
      );
      if (samples.isEmpty) {
        return;
      }
      _controller?.add(
        AudioFrame(
          samples: samples,
          sampleRate: config.sampleRate,
          channels: config.channels,
          sequence: _sequence++,
        ),
      );
    });
  }

  @override
  Future<void> stop() async {
    await _recordSub?.cancel();
    _recordSub = null;
    await _record.stop();
    await _controller?.close();
    _controller = null;
    _sequence = 0;
  }

  @override
  Stream<AudioFrame> frames(AudioStreamConfig config) {
    final controller = _controller;
    if (controller == null) {
      return const Stream.empty();
    }
    return controller.stream;
  }
}
