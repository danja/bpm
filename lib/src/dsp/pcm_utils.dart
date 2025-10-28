import 'dart:typed_data';

class PcmUtils {
  const PcmUtils._();

  /// Converts interleaved little-endian PCM16 bytes into normalized doubles [-1,1].
  static List<double> bytesToFloat32(
    Uint8List bytes, {
    int channels = 1,
  }) {
    final buffer = ByteData.view(bytes.buffer);
    final samples = <double>[];

    // Calculate how many complete samples we can read (2 bytes per sample per channel)
    final bytesPerSample = 2 * channels;
    final completeBytes = (buffer.lengthInBytes ~/ bytesPerSample) * bytesPerSample;

    for (var i = 0; i < completeBytes; i += bytesPerSample) {
      // Mixdown all channels if more than mono.
      var mixed = 0.0;
      for (var channel = 0; channel < channels; channel++) {
        final value = buffer.getInt16(i + channel * 2, Endian.little).toDouble();
        mixed += value / 32768.0;
      }
      samples.add(mixed / channels);
    }
    return samples;
  }
}
