import 'dart:io';
import 'dart:typed_data';

class WavData {
  WavData({
    required this.samples,
    required this.sampleRate,
    required this.channels,
  });

  final List<double> samples;
  final int sampleRate;
  final int channels;
}

WavData loadPcm16Wav(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw ArgumentError('WAV file not found at $path');
  }

  final bytes = file.readAsBytesSync();
  if (bytes.length < 44) {
    throw FormatException('WAV file too short');
  }

  if (String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF' ||
      String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE') {
    throw FormatException('Unsupported WAV header');
  }

  final data = ByteData.sublistView(bytes);

  int? sampleRate;
  int? bitsPerSample;
  int? channels;
  Uint8List? pcmBytes;

  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final chunkId = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final chunkSize = data.getUint32(offset + 4, Endian.little);
    final chunkStart = offset + 8;
    final chunkEnd = chunkStart + chunkSize;
    if (chunkEnd > bytes.length) {
      break;
    }

    if (chunkId == 'fmt ') {
      if (chunkSize < 16) {
        throw FormatException('Invalid fmt chunk size');
      }
      final audioFormat = data.getUint16(chunkStart, Endian.little);
      channels = data.getUint16(chunkStart + 2, Endian.little);
      sampleRate = data.getUint32(chunkStart + 4, Endian.little);
      bitsPerSample = data.getUint16(chunkStart + 14, Endian.little);
      if (audioFormat != 1 || bitsPerSample != 16) {
        throw FormatException(
          'Only PCM16 WAV files are supported (format=$audioFormat, bits=$bitsPerSample)',
        );
      }
    } else if (chunkId == 'data') {
      pcmBytes = bytes.sublist(chunkStart, chunkEnd);
    }

    offset = chunkEnd + (chunkSize.isOdd ? 1 : 0);
  }

  if (sampleRate == null ||
      bitsPerSample == null ||
      channels == null ||
      pcmBytes == null) {
    throw FormatException('Incomplete WAV file (missing fmt or data chunk)');
  }

  final bytesPerSample = bitsPerSample ~/ 8;
  final frameSize = bytesPerSample * channels;
  final frameCount = pcmBytes.length ~/ frameSize;
  final samples = List<double>.filled(frameCount, 0);
  final pcmData = ByteData.sublistView(pcmBytes);

  for (var i = 0; i < frameCount; i++) {
    var sum = 0.0;
    for (var ch = 0; ch < channels; ch++) {
      final index = (i * channels + ch) * bytesPerSample;
      final sample = pcmData.getInt16(index, Endian.little) / 32768.0;
      sum += sample;
    }
    samples[i] = sum / channels;
  }

  return WavData(
    samples: samples,
    sampleRate: sampleRate,
    channels: channels,
  );
}
