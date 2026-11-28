import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Decoded mono floating-point PCM buffer normalized to `[-1.0, 1.0]`.
class AudioPcmData {
  const AudioPcmData({
    required this.samples,
    required this.sampleRate,
    required this.channels,
    required this.durationMs,
    required this.decodeMs,
    required this.estimatedPeakBytes,
  });

  final Float32List samples;
  final int sampleRate;
  final int channels;
  final int durationMs;
  final int decodeMs;
  final int estimatedPeakBytes;
}

/// Optional delegate used in tests or custom native decoder integrations.
typedef AudioDecodeDelegate =
    Future<AudioPcmData> Function(String filePath, {required int maxDurationMs});

/// Decodes RIFF/WAVE bytes directly in pure Dart to mono [Float32List].
AudioPcmData decodeWavBytesToMonoFloat(
  Uint8List bytes, {
  int maxDurationMs = 45000,
}) {
  final watch = Stopwatch()..start();
  if (bytes.length < 44) {
    throw const FormatException('WAV 数据长度不足');
  }
  if (bytes[0] != 0x52 ||
      bytes[1] != 0x49 ||
      bytes[2] != 0x46 ||
      bytes[3] != 0x46 ||
      bytes[8] != 0x57 ||
      bytes[9] != 0x41 ||
      bytes[10] != 0x56 ||
      bytes[11] != 0x45) {
    throw const FormatException('非法的 RIFF/WAVE 头');
  }

  final bd = ByteData.sublistView(bytes);
  var offset = 12;
  int? audioFormat;
  int? channels;
  int? sampleRate;
  int? bitsPerSample;
  int? dataOffset;
  int? dataLength;

  while (offset + 8 <= bytes.length) {
    final chunkId = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final chunkSize = bd.getUint32(offset + 4, Endian.little);
    final payloadStart = offset + 8;
    final available = math.max(0, math.min(chunkSize, bytes.length - payloadStart));
    if (chunkId == 'fmt ' && available >= 16) {
      audioFormat = bd.getUint16(payloadStart, Endian.little);
      channels = bd.getUint16(payloadStart + 2, Endian.little);
      sampleRate = bd.getUint32(payloadStart + 4, Endian.little);
      bitsPerSample = bd.getUint16(payloadStart + 14, Endian.little);
    } else if (chunkId == 'data') {
      dataOffset = payloadStart;
      dataLength = available;
      break;
    }
    final paddedSize = chunkSize.isOdd ? chunkSize + 1 : chunkSize;
    offset = payloadStart + paddedSize;
  }

  if (audioFormat == null ||
      channels == null ||
      sampleRate == null ||
      bitsPerSample == null ||
      dataOffset == null ||
      dataLength == null) {
    throw const FormatException('WAV 缺少 fmt 或 data 块');
  }
  if (channels <= 0 || sampleRate < 4000) {
    throw const FormatException('WAV 采样率或声道数无效');
  }
  final isPcm = audioFormat == 1;
  final isFloat = audioFormat == 3 && bitsPerSample == 32;
  if (!isPcm && !isFloat) {
    throw FormatException('暂不支持的 WAV 编码格式: format=$audioFormat, bits=$bitsPerSample');
  }
  if (isPcm &&
      bitsPerSample != 8 &&
      bitsPerSample != 16 &&
      bitsPerSample != 24 &&
      bitsPerSample != 32) {
    throw FormatException('暂不支持的 PCM 位深: $bitsPerSample');
  }

  final bytesPerSample = bitsPerSample ~/ 8;
  final frameBytes = bytesPerSample * channels;
  final totalFrames = dataLength ~/ frameBytes;
  final maxFrames = ((maxDurationMs.clamp(500, 180000) * sampleRate) / 1000)
      .round();
  final frameCount = math.min(totalFrames, maxFrames);
  final out = Float32List(frameCount);

  for (var f = 0; f < frameCount; f++) {
    final framePos = dataOffset + f * frameBytes;
    var sum = 0.0;
    for (var ch = 0; ch < channels; ch++) {
      final pos = framePos + ch * bytesPerSample;
      double sampleVal;
      if (isFloat) {
        sampleVal = bd.getFloat32(pos, Endian.little);
      } else if (bitsPerSample == 8) {
        sampleVal = (bytes[pos] - 128) / 128.0;
      } else if (bitsPerSample == 16) {
        sampleVal = bd.getInt16(pos, Endian.little) / 32768.0;
      } else if (bitsPerSample == 24) {
        var v = bytes[pos] | (bytes[pos + 1] << 8) | (bytes[pos + 2] << 16);
        if ((v & 0x800000) != 0) {
          v |= ~0xFFFFFF;
        }
        sampleVal = v / 8388608.0;
      } else {
        sampleVal = bd.getInt32(pos, Endian.little) / 2147483648.0;
      }
      if (!sampleVal.isFinite) sampleVal = 0.0;
      sum += sampleVal.clamp(-1.0, 1.0);
    }
    out[f] = sum / channels;
  }

  watch.stop();
  final durationMs = ((frameCount * 1000) / sampleRate).round();
  return AudioPcmData(
    samples: out,
    sampleRate: sampleRate,
    channels: 1,
    durationMs: durationMs,
    decodeMs: watch.elapsedMilliseconds,
    estimatedPeakBytes: bytes.length + out.lengthInBytes,
  );
}

/// Converts little-endian mono PCM16 bytes into normalized [Float32List].
Float32List pcm16BytesToFloat32(Uint8List pcm16Bytes) {
  final count = pcm16Bytes.length ~/ 2;
  final out = Float32List(count);
  final bd = ByteData.sublistView(pcm16Bytes);
  for (var i = 0; i < count; i++) {
    out[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return out;
}

/// Hybrid pure-Dart WAV + platform native decoder (MediaCodec / Media Foundation).
class AudioPcmDecoder {
  AudioPcmDecoder({
    AudioDecodeDelegate? customDelegate,
    Future<Directory> Function()? tempDirProvider,
  }) : _customDelegate = customDelegate,
       _tempDirProvider = tempDirProvider ?? (() async => Directory.systemTemp);

  static const MethodChannel _channel = MethodChannel(
    'com.livecall.studio/audio_decoder',
  );

  final AudioDecodeDelegate? _customDelegate;
  final Future<Directory> Function() _tempDirProvider;

  static bool _looksLikeWav(Uint8List bytes) {
    return bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x41 &&
        bytes[10] == 0x56 &&
        bytes[11] == 0x45;
  }

  Future<AudioPcmData> decodeFile(
    String filePath, {
    int maxDurationMs = 45000,
  }) async {
    if (_customDelegate != null) {
      return _customDelegate(filePath, maxDurationMs: maxDurationMs);
    }
    final file = File(filePath);
    if (!file.existsSync()) {
      throw FileSystemException('音频文件不存在', filePath);
    }

    if (filePath.toLowerCase().endsWith('.wav')) {
      return Isolate.run(() {
        final bytes = File(filePath).readAsBytesSync();
        return decodeWavBytesToMonoFloat(bytes, maxDurationMs: maxDurationMs);
      });
    } else {
      final raf = file.openSync();
      final Uint8List header;
      try {
        header = raf.readSync(12);
      } finally {
        raf.closeSync();
      }
      if (_looksLikeWav(header)) {
        return Isolate.run(() {
          final bytes = File(filePath).readAsBytesSync();
          return decodeWavBytesToMonoFloat(bytes, maxDurationMs: maxDurationMs);
        });
      }
    }

    final watch = Stopwatch()..start();
    final response = await _channel.invokeMapMethod<String, dynamic>(
      'decodeToMonoPcm16',
      <String, Object>{
        'filePath': filePath,
        'maxDurationMs': maxDurationMs,
      },
    );
    if (response == null) {
      throw const FormatException('原生音频解码器返回空结果');
    }
    final pcmBytes = response['pcm16Bytes'];
    final sampleRate = (response['sampleRate'] as num?)?.toInt() ?? 0;
    final durationMs = (response['durationMs'] as num?)?.toInt() ?? 0;
    final nativeDecodeMs = (response['decodeMs'] as num?)?.toInt() ?? 0;
    if (pcmBytes is! Uint8List || sampleRate <= 0) {
      throw const FormatException('原生音频解码输出格式无效');
    }
    final samples = pcm16BytesToFloat32(pcmBytes);
    watch.stop();
    final computedDuration = durationMs > 0
        ? durationMs
        : ((samples.length * 1000) / sampleRate).round();
    return AudioPcmData(
      samples: samples,
      sampleRate: sampleRate,
      channels: 1,
      durationMs: computedDuration,
      decodeMs: math.max(nativeDecodeMs, watch.elapsedMilliseconds),
      estimatedPeakBytes: pcmBytes.length + samples.lengthInBytes,
    );
  }

  Future<AudioPcmData> decodeBytes(
    Uint8List bytes, {
    String fileExtensionHint = '.mp3',
    int maxDurationMs = 45000,
  }) async {
    if (_looksLikeWav(bytes)) {
      return Isolate.run(
        () => decodeWavBytesToMonoFloat(bytes, maxDurationMs: maxDurationMs),
      );
    }

    final dir = await _tempDirProvider();
    final safeExt = fileExtensionHint.startsWith('.')
        ? fileExtensionHint
        : '.$fileExtensionHint';
    final tempFile = File(
      '${dir.path}${Platform.pathSeparator}cbm_probe_${DateTime.now().microsecondsSinceEpoch}$safeExt',
    );
    await tempFile.writeAsBytes(bytes, flush: true);
    try {
      return await decodeFile(tempFile.path, maxDurationMs: maxDurationMs);
    } finally {
      await tempFile.delete().catchError((Object _) => tempFile);
    }
  }
}
