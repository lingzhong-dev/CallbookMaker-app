import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../models/callbook_models.dart';

const int kDownbeatAlgorithmVersion = 1;

/// Reserved metadata interface for future automatic BPM estimation integration.
abstract interface class AutoBpmEstimatorHook {
  bool get supportsAutomaticBpmEstimation;
}

/// Staged execution timings & memory telemetry for downbeat analysis.
class DownbeatTelemetry {
  const DownbeatTelemetry({
    this.fetchMs = 0,
    this.decodeMs = 0,
    this.resampleMs = 0,
    this.analyzeMs = 0,
    this.analyzedDurationMs = 0,
    this.fetchedBytes = 0,
    this.estimatedPeakBytes = 0,
  });

  final int fetchMs;
  final int decodeMs;
  final int resampleMs;
  final int analyzeMs;
  final int analyzedDurationMs;
  final int fetchedBytes;
  final int estimatedPeakBytes;
}

/// Ranked downbeat offset candidate produced for a known BPM.
class DownbeatCandidate {
  const DownbeatCandidate({
    required this.offsetMs,
    required this.confidence,
    required this.label,
  });

  final int offsetMs;
  final double confidence;
  final String label;
}

/// Analysis output binding source identity, BPM snapshot, candidates, and telemetry.
class DownbeatAnalysisResult {
  const DownbeatAnalysisResult({
    required this.requestId,
    required this.sourceFingerprint,
    required this.algorithmVersion,
    required this.knownBpm,
    required this.reliable,
    required this.statusMessage,
    this.audibleStartMs,
    this.candidates = const [],
    this.telemetry = const DownbeatTelemetry(),
    this.supportsAutoBpmExtension = false,
  });

  final int requestId;
  final String sourceFingerprint;
  final int algorithmVersion;
  final int knownBpm;
  final bool reliable;
  final String statusMessage;
  final int? audibleStartMs;
  final List<DownbeatCandidate> candidates;
  final DownbeatTelemetry telemetry;
  final bool supportsAutoBpmExtension;
}

/// Controller-facing async state for downbeat alignment prototype.
class DownbeatAnalysisState {
  const DownbeatAnalysisState({
    this.isAnalyzing = false,
    this.activeRequestId = 0,
    this.stageMessage = '',
    this.result,
    this.errorMessage,
  });

  final bool isAnalyzing;
  final int activeRequestId;
  final String stageMessage;
  final DownbeatAnalysisResult? result;
  final String? errorMessage;

  DownbeatAnalysisState copyWith({
    bool? isAnalyzing,
    int? activeRequestId,
    String? stageMessage,
    DownbeatAnalysisResult? result,
    bool clearResult = false,
    String? errorMessage,
    bool clearError = false,
  }) => DownbeatAnalysisState(
    isAnalyzing: isAnalyzing ?? this.isAnalyzing,
    activeRequestId: activeRequestId ?? this.activeRequestId,
    stageMessage: stageMessage ?? this.stageMessage,
    result: clearResult ? null : (result ?? this.result),
    errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
  );
}

/// Runs known-BPM onset + beat-phase analysis inside a background [Isolate].
Future<DownbeatAnalysisResult> analyzeKnownBpmPcmInIsolate({
  required Float32List samples,
  required int sampleRate,
  required int knownBpm,
  required int beatsPerBar,
  required int requestId,
  required String sourceFingerprint,
  required int fetchMs,
  required int decodeMs,
  required int fetchedBytes,
  required int decodePeakBytes,
}) {
  return Isolate.run(
    () => analyzeKnownBpmPcmSync(
      samples: samples,
      sampleRate: sampleRate,
      knownBpm: knownBpm,
      beatsPerBar: beatsPerBar,
      requestId: requestId,
      sourceFingerprint: sourceFingerprint,
      fetchMs: fetchMs,
      decodeMs: decodeMs,
      fetchedBytes: fetchedBytes,
      decodePeakBytes: decodePeakBytes,
    ),
  );
}

/// Pure-Dart DSP prototype for audible start & beat-phase candidates under known BPM.
DownbeatAnalysisResult analyzeKnownBpmPcmSync({
  required Float32List samples,
  required int sampleRate,
  required int knownBpm,
  required int beatsPerBar,
  required int requestId,
  required String sourceFingerprint,
  int fetchMs = 0,
  int decodeMs = 0,
  int fetchedBytes = 0,
  int decodePeakBytes = 0,
}) {
  const targetRate = 16000;
  final resampleWatch = Stopwatch()..start();
  final Float32List workingSamples;
  final int workingRate;
  if (sampleRate != targetRate && sampleRate > 0 && samples.isNotEmpty) {
    workingSamples = _resampleLinear(samples, sampleRate, targetRate);
    workingRate = targetRate;
  } else {
    workingSamples = samples;
    workingRate = sampleRate;
  }
  resampleWatch.stop();

  final analyzeWatch = Stopwatch()..start();
  final safeBpm = knownBpm.clamp(30, 300);
  final analyzedDurationMs = workingRate > 0
      ? ((workingSamples.length * 1000) / workingRate).round()
      : 0;
  final peakBytes = math.max(decodePeakBytes, workingSamples.lengthInBytes) +
      workingSamples.lengthInBytes;

  DownbeatTelemetry buildTelemetry() => DownbeatTelemetry(
    fetchMs: fetchMs,
    decodeMs: decodeMs,
    resampleMs: resampleWatch.elapsedMilliseconds,
    analyzeMs: analyzeWatch.elapsedMilliseconds,
    analyzedDurationMs: analyzedDurationMs,
    fetchedBytes: fetchedBytes,
    estimatedPeakBytes: peakBytes,
  );

  if (workingRate < 8000 || analyzedDurationMs < 1500) {
    analyzeWatch.stop();
    return DownbeatAnalysisResult(
      requestId: requestId,
      sourceFingerprint: sourceFingerprint,
      algorithmVersion: kDownbeatAlgorithmVersion,
      knownBpm: safeBpm,
      reliable: false,
      statusMessage: '无法可靠判断：有效音频时长过短（< 1.5 秒）',
      telemetry: buildTelemetry(),
    );
  }

  const frameSize = 512; // 32ms @ 16kHz
  const hopSize = 160; // 10ms @ 16kHz
  final frameCount = (workingSamples.length - frameSize) ~/ hopSize + 1;
  if (frameCount < 20) {
    analyzeWatch.stop();
    return DownbeatAnalysisResult(
      requestId: requestId,
      sourceFingerprint: sourceFingerprint,
      algorithmVersion: kDownbeatAlgorithmVersion,
      knownBpm: safeBpm,
      reliable: false,
      statusMessage: '无法可靠判断：有效音频帧不足',
      telemetry: buildTelemetry(),
    );
  }

  final rms = Float64List(frameCount);
  final flux = Float64List(frameCount);

  // Two-band time-domain envelope split (low/kick vs mid-high/transient attack).
  const lpAlpha = 0.08;
  var lpState = 0.0;
  var prevLowLog = 0.0;
  var prevHighLog = 0.0;

  for (var i = 0; i < frameCount; i++) {
    final start = i * hopSize;
    var sumSq = 0.0;
    var lowSq = 0.0;
    var highSq = 0.0;
    for (var j = 0; j < frameSize; j++) {
      final x = workingSamples[start + j].toDouble();
      lpState += lpAlpha * (x - lpState);
      final hp = x - lpState;
      sumSq += x * x;
      lowSq += lpState * lpState;
      highSq += hp * hp;
    }
    rms[i] = math.sqrt(sumSq / frameSize);
    final lowEnergy = math.log(1.0 + 120.0 * math.sqrt(lowSq / frameSize));
    final highEnergy = math.log(1.0 + 120.0 * math.sqrt(highSq / frameSize));
    if (i > 0) {
      final dLow = math.max(0.0, lowEnergy - prevLowLog);
      final dHigh = math.max(0.0, highEnergy - prevHighLog);
      flux[i] = dLow * 1.15 + dHigh * 0.85;
    }
    prevLowLog = lowEnergy;
    prevHighLog = highEnergy;
  }

  final sortedRms = List<double>.from(rms)..sort();
  final p95Rms = sortedRms[(sortedRms.length * 0.95).floor().clamp(0, sortedRms.length - 1)];
  final noiseFloor = sortedRms[(sortedRms.length * 0.15).floor().clamp(0, sortedRms.length - 1)];

  if (p95Rms < 0.002) {
    analyzeWatch.stop();
    return DownbeatAnalysisResult(
      requestId: requestId,
      sourceFingerprint: sourceFingerprint,
      algorithmVersion: kDownbeatAlgorithmVersion,
      knownBpm: safeBpm,
      reliable: false,
      statusMessage: '无法可靠判断：音频静音或有效电平过低',
      telemetry: buildTelemetry(),
    );
  }

  // Adaptive multi-frame onset detection for audible start (avoids single-click spikes & fixed -40dBFS cutoff).
  final audibleThreshold = math.max(noiseFloor * 3.5, p95Rms * 0.06);
  const minConfirmFrames = 3;
  int? audibleStartFrame;
  var consecutive = 0;
  for (var i = 0; i < frameCount; i++) {
    if (rms[i] >= audibleThreshold) {
      consecutive++;
      if (consecutive >= minConfirmFrames) {
        audibleStartFrame = i - minConfirmFrames + 1;
        break;
      }
    } else {
      consecutive = 0;
    }
  }

  final int? audibleStartMs = audibleStartFrame != null
      ? (audibleStartFrame * hopSize * 1000 / workingRate).round()
      : null;

  if (audibleStartFrame == null) {
    analyzeWatch.stop();
    return DownbeatAnalysisResult(
      requestId: requestId,
      sourceFingerprint: sourceFingerprint,
      algorithmVersion: kDownbeatAlgorithmVersion,
      knownBpm: safeBpm,
      reliable: false,
      statusMessage: '无法可靠判断：未检测到持续有声起点',
      telemetry: buildTelemetry(),
    );
  }

  // Evaluate onset transient activity after audible start.
  final activeFlux = <double>[
    for (var i = audibleStartFrame; i < frameCount; i++) flux[i],
  ];
  final sortedFlux = List<double>.from(activeFlux)..sort();
  final maxFlux = sortedFlux.last;
  final p95Flux = sortedFlux[(sortedFlux.length * 0.95).floor().clamp(0, sortedFlux.length - 1)];
  final medianFlux = sortedFlux[sortedFlux.length ~/ 2];

  if (maxFlux < 0.035 || (p95Flux - medianFlux) < 0.025) {
    analyzeWatch.stop();
    return DownbeatAnalysisResult(
      requestId: requestId,
      sourceFingerprint: sourceFingerprint,
      algorithmVersion: kDownbeatAlgorithmVersion,
      knownBpm: safeBpm,
      reliable: false,
      audibleStartMs: audibleStartMs,
      statusMessage: '无法可靠判断：未检测到明显节奏瞬态（可能是清唱、纯音或无鼓段落）',
      telemetry: buildTelemetry(),
    );
  }

  // Known-BPM phase histogram over [0, beatMs).
  final beatMs = 60000.0 / safeBpm;
  final numBins = (beatMs / 10.0).round().clamp(16, 120);
  final binWidthMs = beatMs / numBins;
  final phaseHist = Float64List(numBins);
  final phaseCounts = Float64List(numBins);
  final fluxNoise = medianFlux + 0.015;

  var activePeakCount = 0;
  for (var i = math.max(1, audibleStartFrame); i < frameCount - 1; i++) {
    final excess = math.max(0.0, flux[i] - fluxNoise);
    if (excess <= 0.0) continue;
    final isLocalPeak = flux[i] >= flux[i - 1] && flux[i] >= flux[i + 1];
    final weight = isLocalPeak ? excess * 1.5 : excess * 0.45;
    if (isLocalPeak && excess > (p95Flux - medianFlux) * 0.25) {
      activePeakCount++;
    }
    final tMs = (i * hopSize * 1000.0) / workingRate;
    final phaseMs = tMs % beatMs;
    final exactBin = phaseMs / binWidthMs;
    final centerBin = exactBin.floor() % numBins;
    for (var delta = -1; delta <= 1; delta++) {
      final b = (centerBin + delta + numBins) % numBins;
      final kernel = delta == 0 ? 0.6 : 0.2;
      phaseHist[b] += weight * kernel;
      if (isLocalPeak && delta == 0) {
        phaseCounts[b] += 1.0;
      }
    }
  }

  final totalHistEnergy = phaseHist.fold<double>(0.0, (a, b) => a + b);
  if (totalHistEnergy <= 1e-6 || activePeakCount < 2) {
    analyzeWatch.stop();
    return DownbeatAnalysisResult(
      requestId: requestId,
      sourceFingerprint: sourceFingerprint,
      algorithmVersion: kDownbeatAlgorithmVersion,
      knownBpm: safeBpm,
      reliable: false,
      audibleStartMs: audibleStartMs,
      statusMessage: '无法可靠判断：有效节拍峰值不足',
      telemetry: buildTelemetry(),
    );
  }

  final sortedBins = List<double>.from(phaseHist)..sort();
  final medianBin = sortedBins[sortedBins.length ~/ 2];
  final meanBin = totalHistEnergy / numBins;
  var sqDiff = 0.0;
  for (final v in phaseHist) {
    final d = v - meanBin;
    sqDiff += d * d;
  }
  final stdBin = math.sqrt(sqDiff / numBins);

  // Rank distinct phase peaks separated by >= 18% of one beat.
  final minBinSeparation = math.max(2, (numBins * 0.18).round());
  final rankedBins = <int>[];
  final binOrder = List<int>.generate(numBins, (i) => i)
    ..sort((a, b) => phaseHist[b].compareTo(phaseHist[a]));

  for (final bin in binOrder) {
    if (phaseHist[bin] <= 0.0) break;
    final tooClose = rankedBins.any((picked) {
      final rawDiff = (bin - picked).abs();
      final circDiff = math.min(rawDiff, numBins - rawDiff);
      return circDiff < minBinSeparation;
    });
    if (!tooClose) {
      rankedBins.add(bin);
      if (rankedBins.length >= 3) break;
    }
  }

  if (rankedBins.isEmpty) {
    analyzeWatch.stop();
    return DownbeatAnalysisResult(
      requestId: requestId,
      sourceFingerprint: sourceFingerprint,
      algorithmVersion: kDownbeatAlgorithmVersion,
      knownBpm: safeBpm,
      reliable: false,
      audibleStartMs: audibleStartMs,
      statusMessage: '无法可靠判断：未能聚合出稳定的节拍相位',
      telemetry: buildTelemetry(),
    );
  }

  final topVal = phaseHist[rankedBins.first];
  final contrastRatio = topVal / math.max(1e-6, medianBin);
  final zScore = (topVal - meanBin) / math.max(1e-6, stdBin);

  // Count how many expected beats after audibleStartMs actually exhibit an onset near the top phase.
  final topPhaseMs = (rankedBins.first + 0.5) * binWidthMs;
  var expectedBeats = 0;
  var matchedBeats = 0;
  final anchorStartMs = audibleStartMs ?? 0;
  var k = ((anchorStartMs - 40.0 - topPhaseMs) / beatMs).ceil();
  if (k < 0) k = 0;
  while (true) {
    final beatTimeMs = topPhaseMs + k * beatMs;
    if (beatTimeMs > analyzedDurationMs - 40.0) break;
    expectedBeats++;
    final frameCenter = ((beatTimeMs * workingRate) / (1000.0 * hopSize)).round();
    var localMaxFlux = 0.0;
    for (var f = math.max(0, frameCenter - 4);
        f <= math.min(frameCount - 1, frameCenter + 4);
        f++) {
      if (flux[f] > localMaxFlux) localMaxFlux = flux[f];
    }
    if (localMaxFlux >= fluxNoise + (p95Flux - medianFlux) * 0.25) {
      matchedBeats++;
    }
    k++;
  }
  final hitRatio = expectedBeats > 0 ? matchedBeats / expectedBeats : 0.0;

  if (contrastRatio < 1.65 || zScore < 1.9 || hitRatio < 0.38) {
    analyzeWatch.stop();
    return DownbeatAnalysisResult(
      requestId: requestId,
      sourceFingerprint: sourceFingerprint,
      algorithmVersion: kDownbeatAlgorithmVersion,
      knownBpm: safeBpm,
      reliable: false,
      audibleStartMs: audibleStartMs,
      statusMessage: '无法可靠判断：周期节拍与当前 BPM ($safeBpm) 吻合度或置信度不足',
      telemetry: buildTelemetry(),
    );
  }

  final candidates = <DownbeatCandidate>[];
  for (var idx = 0; idx < rankedBins.length; idx++) {
    final bin = rankedBins[idx];
    final val = phaseHist[bin];
    if (idx > 0 && val < topVal * 0.35) continue;

    final phaseMs = (bin + 0.5) * binWidthMs;
    var firstK = ((anchorStartMs - 50.0 - phaseMs) / beatMs).ceil();
    if (firstK < 0) firstK = 0;

    // Refine first strong onset beat near audibleStartMs (also checks bar-1 accent if clear).
    var bestBeatMs = phaseMs + firstK * beatMs;
    final scanLimit = math.max(1, beatsPerBar);
    var bestScore = -1.0;
    for (var step = 0; step < scanLimit; step++) {
      final candidateMs = phaseMs + (firstK + step) * beatMs;
      if (candidateMs > analyzedDurationMs - 40.0 ||
          candidateMs > kMaxSongOffsetMs) {
        break;
      }
      final fc = ((candidateMs * workingRate) / (1000.0 * hopSize)).round();
      var localPeak = 0.0;
      for (var f = math.max(0, fc - 3);
          f <= math.min(frameCount - 1, fc + 3);
          f++) {
        if (flux[f] > localPeak) localPeak = flux[f];
      }
      if (step == 0 && localPeak > (p95Flux - medianFlux) * 0.35) {
        bestBeatMs = candidateMs;
        break;
      }
      if (localPeak > bestScore) {
        bestScore = localPeak;
        bestBeatMs = candidateMs;
      }
    }

    final offsetMs = clampSongOffsetMs(bestBeatMs.round());
    final rawScore =
        ((val / topVal) * (0.45 * hitRatio + 0.35 * math.min(1.0, zScore / 4.5) + 0.20 * math.min(1.0, contrastRatio / 5.0)))
            .clamp(0.05, 0.99);
    candidates.add(
      DownbeatCandidate(
        offsetMs: offsetMs,
        confidence: double.parse(rawScore.toStringAsFixed(2)),
        label: idx == 0 ? '推荐首拍候选' : '备选相位 ${idx + 1}',
      ),
    );
  }

  analyzeWatch.stop();
  final topConf = candidates.isNotEmpty ? candidates.first.confidence : 0.0;
  if (candidates.isEmpty || topConf < 0.45) {
    return DownbeatAnalysisResult(
      requestId: requestId,
      sourceFingerprint: sourceFingerprint,
      algorithmVersion: kDownbeatAlgorithmVersion,
      knownBpm: safeBpm,
      reliable: false,
      audibleStartMs: audibleStartMs,
      statusMessage: '无法可靠判断：节拍置信度过低（${(topConf * 100).round()}%）',
      telemetry: buildTelemetry(),
    );
  }

  return DownbeatAnalysisResult(
    requestId: requestId,
    sourceFingerprint: sourceFingerprint,
    algorithmVersion: kDownbeatAlgorithmVersion,
    knownBpm: safeBpm,
    reliable: true,
    statusMessage: '已生成 ${candidates.length} 个首拍候选（$safeBpm BPM）',
    audibleStartMs: audibleStartMs,
    candidates: List<DownbeatCandidate>.unmodifiable(candidates),
    telemetry: buildTelemetry(),
  );
}

Float32List _resampleLinear(Float32List input, int srcRate, int dstRate) {
  if (input.isEmpty || srcRate == dstRate) return input;
  final outLen = math.max(1, ((input.length * dstRate) / srcRate).round());
  final out = Float32List(outLen);
  final step = srcRate / dstRate;
  for (var i = 0; i < outLen; i++) {
    final pos = i * step;
    final idx0 = pos.floor().clamp(0, input.length - 1);
    final idx1 = math.min(idx0 + 1, input.length - 1);
    final frac = pos - idx0;
    out[i] = (input[idx0] * (1.0 - frac) + input[idx1] * frac).toDouble();
  }
  return out;
}
