import 'dart:async';
import 'dart:typed_data';

import 'package:bpm/src/audio/audio_stream_source.dart';
import 'package:bpm/src/dsp/pcm_utils.dart';
import 'package:bpm/src/models/bpm_models.dart';
import 'package:bpm/src/utils/app_logger.dart';
import 'package:record/record.dart';

class RecordAudioStreamSource implements AudioStreamSource {
  RecordAudioStreamSource({AudioRecorder? recorder})
      : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;
  final _logger = AppLogger();
  StreamController<AudioFrame>? _controller;
  StreamSubscription<Uint8List>? _recordSub;
  int _sequence = 0;

  @override
  Future<void> start(AudioStreamConfig config) async {
    _logger.info('RecordAudioStreamSource.start() called', source: 'Audio');

    final hasPermission = await _recorder.hasPermission();
    _logger.info('Has permission: $hasPermission', source: 'Audio');

    if (!hasPermission) {
      _logger.error('Microphone permission not granted', source: 'Audio');
      throw Exception('Microphone permission not granted');
    }

    // Ensure controller exists (may have been created by frames() call)
    _controller ??= StreamController<AudioFrame>.broadcast(
      onCancel: () => stop(),
    );
    _logger.info('Stream controller ready', source: 'Audio');

    final recordConfig = RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      bitRate: config.sampleRate * 16 * config.channels,
      sampleRate: config.sampleRate,
      numChannels: config.channels,
    );

    _logger.info('Starting recorder with config: sampleRate=${config.sampleRate}, channels=${config.channels}', source: 'Audio');

    try {
      // Check if already recording
      final isRecording = await _recorder.isRecording();
      _logger.debug('Is already recording: $isRecording', source: 'Audio');

      if (isRecording) {
        await _recorder.stop();
        _logger.info('Stopped existing recording', source: 'Audio');
      }

      final stream = await _recorder.startStream(recordConfig);
      _logger.info('Recorder started, got stream', source: 'Audio');

      var frameCount = 0;
      var totalSamples = 0;
      _recordSub = stream.listen(
        (chunk) {
          final samples = PcmUtils.bytesToFloat32(
            chunk,
            channels: config.channels,
          );
          if (samples.isEmpty) {
            _logger.warning('Empty samples after conversion', source: 'Audio');
            return;
          }
          frameCount++;
          totalSamples += samples.length;
          final durationSecs = totalSamples / config.sampleRate;

          // Log every 20th frame to track buffering progress
          if (frameCount % 20 == 0) {
            _logger.info('Frame $frameCount: ${samples.length} samples, total ${durationSecs.toStringAsFixed(1)}s audio received', source: 'Audio');
          }
          _controller?.add(
            AudioFrame(
              samples: samples,
              sampleRate: config.sampleRate,
              channels: config.channels,
              sequence: _sequence++,
            ),
          );
        },
        onError: (error) {
          _logger.error('Audio stream error: $error', source: 'Audio');
          _controller?.addError(
            Exception('Audio stream error: $error'),
          );
        },
        onDone: () {
          _logger.warning('Audio stream DONE - this should not happen during recording!', source: 'Audio');
        },
        cancelOnError: false,
      );
      _logger.info('Stream listener set up successfully', source: 'Audio');
    } catch (e) {
      _logger.error('Error starting recorder: $e', source: 'Audio');
      await _controller?.close();
      _controller = null;
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    await _recordSub?.cancel();
    _recordSub = null;
    await _recorder.stop();
    await _controller?.close();
    _controller = null;
    _sequence = 0;
  }

  @override
  Stream<AudioFrame> frames(AudioStreamConfig config) {
    // Create controller if it doesn't exist yet (before start() is called)
    // This ensures coordinator can subscribe before audio starts flowing
    _controller ??= StreamController<AudioFrame>.broadcast(
      onCancel: () => stop(),
    );
    _logger.debug('frames() returning stream (controller ready)', source: 'Audio');
    return _controller!.stream;
  }
}
