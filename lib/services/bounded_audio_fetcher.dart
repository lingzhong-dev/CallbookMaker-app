import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Error categories for bounded HTTP Range audio fetching.
enum BoundedFetchErrorKind {
  invalidUrl,
  invalidContentRange,
  rangeNotSatisfiable,
  httpStatus,
  timeout,
  cancelled,
  network,
  emptyBody,
}

/// Typed exception thrown by [BoundedAudioFetcher].
class BoundedAudioFetchException implements Exception {
  const BoundedAudioFetchException(this.kind, this.message);

  final BoundedFetchErrorKind kind;
  final String message;

  @override
  String toString() => 'BoundedAudioFetchException(${kind.name}): $message';
}

/// Result of a bounded HTTP audio prefix fetch.
class BoundedAudioFetchResult {
  const BoundedAudioFetchResult({
    required this.bytes,
    required this.statusCode,
    required this.fetchedBytes,
    required this.fetchMs,
    required this.partialRangeUsed,
    this.totalBytes,
    this.contentRange,
  });

  final Uint8List bytes;
  final int statusCode;
  final int fetchedBytes;
  final int fetchMs;
  final bool partialRangeUsed;
  final int? totalBytes;
  final String? contentRange;
}

/// Fetches a strictly byte-bounded prefix of a remote audio stream using HTTP Range.
class BoundedAudioFetcher {
  BoundedAudioFetcher({
    http.Client? httpClient,
    this.defaultMaxBytes = 1536 * 1024,
    this.timeout = const Duration(seconds: 12),
  }) : _http = httpClient ?? http.Client(),
       _ownsClient = httpClient == null;

  final http.Client _http;
  final bool _ownsClient;
  final int defaultMaxBytes;
  final Duration timeout;

  static final RegExp _contentRangeRegex = RegExp(
    r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$',
    caseSensitive: false,
  );

  /// Fetches at most [maxBytes] bytes starting at byte 0 from [url].
  Future<BoundedAudioFetchResult> fetchPrefix(
    String url, {
    int? maxBytes,
    bool Function()? isCancelled,
  }) async {
    final cleanUrl = url.trim();
    final uri = Uri.tryParse(cleanUrl);
    if (uri == null || !uri.hasScheme || (!uri.isScheme('http') && !uri.isScheme('https'))) {
      throw const BoundedAudioFetchException(
        BoundedFetchErrorKind.invalidUrl,
        '无效的音频 URL',
      );
    }

    final limitBytes = (maxBytes ?? defaultMaxBytes).clamp(4096, 16 * 1024 * 1024);
    final watch = Stopwatch()..start();

    if (isCancelled?.call() == true) {
      throw const BoundedAudioFetchException(
        BoundedFetchErrorKind.cancelled,
        '分析已取消',
      );
    }

    final request = http.Request('GET', uri);
    request.headers['Range'] = 'bytes=0-${limitBytes - 1}';

    final http.StreamedResponse response;
    try {
      response = await _http.send(request).timeout(timeout);
    } on TimeoutException {
      throw const BoundedAudioFetchException(
        BoundedFetchErrorKind.timeout,
        '在线音频片段拉取超时',
      );
    } on BoundedAudioFetchException {
      rethrow;
    } catch (err) {
      throw BoundedAudioFetchException(
        BoundedFetchErrorKind.network,
        '拉取音频失败：$err',
      );
    }

    if (isCancelled?.call() == true) {
      throw const BoundedAudioFetchException(
        BoundedFetchErrorKind.cancelled,
        '分析已取消',
      );
    }

    if (response.statusCode == 416) {
      await response.stream.drain<void>().catchError((Object _) {});
      throw const BoundedAudioFetchException(
        BoundedFetchErrorKind.rangeNotSatisfiable,
        '服务器返回 HTTP 416（Range 超出音频范围）',
      );
    }

    if (response.statusCode != 200 && response.statusCode != 206) {
      await response.stream.drain<void>().catchError((Object _) {});
      throw BoundedAudioFetchException(
        BoundedFetchErrorKind.httpStatus,
        '服务器返回 HTTP ${response.statusCode}',
      );
    }

    final partial = response.statusCode == 206;
    String? contentRange;
    int? totalBytes;
    if (partial) {
      contentRange = response.headers['content-range']?.trim();
      if (contentRange == null || contentRange.isEmpty) {
        await response.stream.drain<void>().catchError((Object _) {});
        throw const BoundedAudioFetchException(
          BoundedFetchErrorKind.invalidContentRange,
          'HTTP 206 响应缺少 Content-Range 头',
        );
      }
      final match = _contentRangeRegex.firstMatch(contentRange);
      if (match == null) {
        await response.stream.drain<void>().catchError((Object _) {});
        throw BoundedAudioFetchException(
          BoundedFetchErrorKind.invalidContentRange,
          '无效的 Content-Range 格式：$contentRange',
        );
      }
      final start = int.parse(match.group(1)!);
      final end = int.parse(match.group(2)!);
      final totalRaw = match.group(3)!;
      if (start != 0 || end < start) {
        await response.stream.drain<void>().catchError((Object _) {});
        throw BoundedAudioFetchException(
          BoundedFetchErrorKind.invalidContentRange,
          '非法的 Content-Range 字节区间：$contentRange',
        );
      }
      if (totalRaw != '*') {
        totalBytes = int.tryParse(totalRaw);
        if (totalBytes != null && totalBytes <= end) {
          await response.stream.drain<void>().catchError((Object _) {});
          throw BoundedAudioFetchException(
            BoundedFetchErrorKind.invalidContentRange,
            'Content-Range 结束偏移超出总长度：$contentRange',
          );
        }
      }
    }

    final bytes = await _readCappedStream(
      response.stream,
      limitBytes: limitBytes,
      remainingBudget: timeout - watch.elapsed,
      isCancelled: isCancelled,
    );
    if (bytes.isEmpty) {
      throw const BoundedAudioFetchException(
        BoundedFetchErrorKind.emptyBody,
        '下载到的音频字节为空',
      );
    }

    watch.stop();
    return BoundedAudioFetchResult(
      bytes: bytes,
      statusCode: response.statusCode,
      fetchedBytes: bytes.length,
      fetchMs: watch.elapsedMilliseconds,
      partialRangeUsed: partial,
      totalBytes: totalBytes,
      contentRange: contentRange,
    );
  }

  Future<Uint8List> _readCappedStream(
    Stream<List<int>> stream, {
    required int limitBytes,
    required Duration remainingBudget,
    bool Function()? isCancelled,
  }) {
    final effectiveTimeout = remainingBudget > const Duration(milliseconds: 50)
        ? remainingBudget
        : const Duration(milliseconds: 50);
    final builder = BytesBuilder(copy: false);
    final completer = Completer<Uint8List>();
    late StreamSubscription<List<int>> sub;
    late Timer timer;

    Future<void> finishWithError(Object error) async {
      timer.cancel();
      await sub.cancel().catchError((Object _) {});
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    }

    Future<void> finishSuccess() async {
      timer.cancel();
      await sub.cancel().catchError((Object _) {});
      if (!completer.isCompleted) {
        completer.complete(builder.takeBytes());
      }
    }

    timer = Timer(effectiveTimeout, () {
      unawaited(
        finishWithError(
          const BoundedAudioFetchException(
            BoundedFetchErrorKind.timeout,
            '在线音频读取超时',
          ),
        ),
      );
    });

    sub = stream.listen(
      (chunk) {
        if (completer.isCompleted) return;
        if (isCancelled?.call() == true) {
          unawaited(
            finishWithError(
              const BoundedAudioFetchException(
                BoundedFetchErrorKind.cancelled,
                '分析已取消',
              ),
            ),
          );
          return;
        }
        if (chunk.isEmpty) return;
        final remaining = limitBytes - builder.length;
        if (remaining <= 0) {
          unawaited(finishSuccess());
          return;
        }
        if (chunk.length >= remaining) {
          builder.add(chunk.sublist(0, remaining));
          unawaited(finishSuccess());
        } else {
          builder.add(chunk);
        }
      },
      onError: (Object err) {
        if (!completer.isCompleted) {
          unawaited(
            finishWithError(
              BoundedAudioFetchException(
                BoundedFetchErrorKind.network,
                '音频流读取中断：$err',
              ),
            ),
          );
        }
      },
      onDone: () {
        timer.cancel();
        if (!completer.isCompleted) {
          completer.complete(builder.takeBytes());
        }
      },
      cancelOnError: true,
    );

    return completer.future;
  }

  void dispose() {
    if (_ownsClient) {
      _http.close();
    }
  }
}
