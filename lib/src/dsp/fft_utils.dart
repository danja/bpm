import 'dart:math';

class FftResult {
  const FftResult({
    required this.magnitudes,
    required this.size,
  });

  final List<double> magnitudes;
  final int size;
}

class FftUtils {
  const FftUtils._();

  static FftResult magnitudeSpectrum(List<double> samples) {
    final n = samples.length;
    if (!_isPowerOfTwo(n)) {
      throw ArgumentError('FFT input length must be a power of two (was $n)');
    }
    final real = List<double>.from(samples);
    final imag = List<double>.filled(n, 0);
    _fft(real, imag);
    final half = n ~/ 2;
    final magnitudes = List<double>.filled(half, 0);
    for (var i = 0; i < half; i++) {
      final re = real[i];
      final im = imag[i];
      magnitudes[i] = sqrt(re * re + im * im);
    }
    return FftResult(magnitudes: magnitudes, size: n);
  }

  static void _fft(List<double> real, List<double> imag) {
    final n = real.length;
    if (n == 0) {
      return;
    }
    final levels = _log2(n);
    _bitReverseCopy(real, imag, levels);

    for (var size = 2; size <= n; size <<= 1) {
      final halfSize = size >> 1;
      final angle = -2 * pi / size;
      final wPhaseStepReal = cos(angle);
      final wPhaseStepImag = sin(angle);

      for (var offset = 0; offset < n; offset += size) {
        var wReal = 1.0;
        var wImag = 0.0;

        for (var k = 0; k < halfSize; k++) {
          final evenIndex = offset + k;
          final oddIndex = evenIndex + halfSize;

          final oddReal = real[oddIndex] * wReal - imag[oddIndex] * wImag;
          final oddImag = real[oddIndex] * wImag + imag[oddIndex] * wReal;

          final evenReal = real[evenIndex];
          final evenImag = imag[evenIndex];

          real[oddIndex] = evenReal - oddReal;
          imag[oddIndex] = evenImag - oddImag;

          real[evenIndex] = evenReal + oddReal;
          imag[evenIndex] = evenImag + oddImag;

          final nextWReal = wReal * wPhaseStepReal - wImag * wPhaseStepImag;
          final nextWImag = wReal * wPhaseStepImag + wImag * wPhaseStepReal;
          wReal = nextWReal;
          wImag = nextWImag;
        }
      }
    }
  }

  static void _bitReverseCopy(List<double> real, List<double> imag, int levels) {
    final n = real.length;
    for (var i = 0; i < n; i++) {
      final j = _reverseBits(i, levels);
      if (j > i) {
        final tempReal = real[i];
        real[i] = real[j];
        real[j] = tempReal;

        final tempImag = imag[i];
        imag[i] = imag[j];
        imag[j] = tempImag;
      }
    }
  }

  static int _reverseBits(int value, int width) {
    var result = 0;
    for (var i = 0; i < width; i++) {
      result = (result << 1) | (value & 1);
      value >>= 1;
    }
    return result;
  }

  static bool _isPowerOfTwo(int value) =>
      value > 0 && (value & (value - 1)) == 0;

  static int _log2(int value) {
    var result = 0;
    while (value > 1) {
      value >>= 1;
      result++;
    }
    return result;
  }
}
