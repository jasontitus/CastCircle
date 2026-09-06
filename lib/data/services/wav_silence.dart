import 'dart:io';
import 'dart:typed_data';

/// Prepends silence to a PCM WAV file.
///
/// Why this exists: on Android the first line of a rehearsal lost its opening
/// syllable. The audio output is asleep when playback starts — audio focus is
/// requested and the route opened microseconds before the first samples — and
/// the hardware swallows the start. Every later line is fine because the
/// output is already awake.
///
/// Rather than depend on how the player and platform negotiate that, the
/// first line after an idle period is played with a short run of silence in
/// front. Whatever the platform eats, it eats silence.
class WavSilence {
  WavSilence._();

  /// Parse enough of [bytes] to find the PCM format and the data chunk.
  /// Returns null when this isn't a WAV we understand — callers then use the
  /// original file rather than risk mangling audio.
  static _WavInfo? _parse(Uint8List bytes) {
    if (bytes.length < 44) return null;
    final data = ByteData.sublistView(bytes);
    if (String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF') return null;
    if (String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE') return null;

    var offset = 12;
    int? byteRate;
    int? dataStart;
    int? dataLength;
    while (offset + 8 <= bytes.length) {
      final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final size = data.getUint32(offset + 4, Endian.little);
      final body = offset + 8;
      if (id == 'fmt ' && body + 16 <= bytes.length) {
        final format = data.getUint16(body, Endian.little);
        // 1 = PCM. Anything else (float, compressed) isn't safe to pad with
        // zero bytes.
        if (format != 1) return null;
        byteRate = data.getUint32(body + 8, Endian.little);
      } else if (id == 'data') {
        dataStart = body;
        dataLength = size;
        break;
      }
      // Chunks are word-aligned: an odd size is followed by a pad byte.
      offset = body + size + (size.isOdd ? 1 : 0);
    }
    if (byteRate == null || byteRate == 0 || dataStart == null) return null;
    // Trust the file's length over the header's size field: a truncated file
    // with an optimistic header would otherwise produce a bogus copy.
    final available = bytes.length - dataStart;
    final length = (dataLength == null || dataLength > available)
        ? available
        : dataLength;
    return _WavInfo(
      byteRate: byteRate,
      dataStart: dataStart,
      dataLength: length,
    );
  }

  /// Write [source] to [destination] with [silence] of leading quiet.
  ///
  /// Returns the path written, or [source] unchanged when the file isn't a
  /// PCM WAV or anything goes wrong — a mispadded file would be worse than
  /// the clipped syllable this works around.
  static Future<String> prepend(
    String source,
    String destination, {
    Duration silence = const Duration(milliseconds: 350),
  }) async {
    try {
      final bytes = await File(source).readAsBytes();
      final info = _parse(bytes);
      if (info == null) return source;

      // Whole frames only — a partial frame would shift every sample after it
      // and turn the audio to noise.
      final frameSize = _frameSize(bytes, info);
      var padBytes = (info.byteRate * silence.inMilliseconds / 1000).round();
      padBytes -= padBytes % frameSize;
      if (padBytes <= 0) return source;

      final header = bytes.sublist(0, info.dataStart);
      final audio = bytes.sublist(
        info.dataStart,
        info.dataStart + info.dataLength,
      );
      final out = BytesBuilder()
        ..add(header)
        ..add(Uint8List(padBytes)) // PCM silence is zeroes
        ..add(audio);
      final result = out.toBytes();

      // Fix the two length fields the sizes changed under.
      final view = ByteData.sublistView(result);
      view.setUint32(4, result.length - 8, Endian.little); // RIFF size
      view.setUint32(
        info.dataStart - 4,
        info.dataLength + padBytes,
        Endian.little,
      ); // data chunk size

      await File(destination).writeAsBytes(result, flush: true);
      return destination;
    } catch (_) {
      return source;
    }
  }

  /// Bytes per sample frame (channels x bits/8), read back out of the header.
  static int _frameSize(Uint8List bytes, _WavInfo info) {
    final data = ByteData.sublistView(bytes);
    var offset = 12;
    while (offset + 8 <= bytes.length) {
      final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final size = data.getUint32(offset + 4, Endian.little);
      if (id == 'fmt ') {
        final channels = data.getUint16(offset + 10, Endian.little);
        final bits = data.getUint16(offset + 22, Endian.little);
        final frame = channels * (bits ~/ 8);
        return frame > 0 ? frame : 2;
      }
      offset = offset + 8 + size + (size.isOdd ? 1 : 0);
    }
    return 2; // 16-bit mono, which is what Kokoro emits
  }
}

class _WavInfo {
  const _WavInfo({
    required this.byteRate,
    required this.dataStart,
    required this.dataLength,
  });

  final int byteRate;
  final int dataStart;
  final int dataLength;
}
