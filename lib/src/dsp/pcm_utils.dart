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
    for (var i = 0; i < buffer.lengthInBytes; i += 2 * channels) {
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
