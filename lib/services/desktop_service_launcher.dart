import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;

/// Desktop helper for locating `backend/.env` and launching local FastAPI /
/// NeteaseCloudMusicApiEnhanced processes when the user runs the desktop app directly.
class DesktopServiceLauncher {
  bool get isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  static bool isLoopbackUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    final host = (uri?.host ?? '').toLowerCase();
    return host == '127.0.0.1' || host == 'localhost' || host == '::1';
  }

  static int extractPort(String url, {int fallback = 3000}) {
    final uri = Uri.tryParse(url.trim());
    if (uri != null && uri.hasPort && uri.port > 0) {
      return uri.port;
    }
    return fallback;
  }

  static String normalizeGatewayUrl(String raw) {
    var trimmed = raw.trim();
    if (trimmed.isEmpty) return 'http://127.0.0.1:3000';
    if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
      trimmed = 'http://$trimmed';
    }
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    return trimmed;
  }

  /// Normalizes pasted full browser `Cookie` headers OR raw `MUSIC_U` token strings.
  static String normalizeNeteaseCookie(String raw) {
    var cleaned = raw.trim();
    if (cleaned.length >= 2 &&
        ((cleaned.startsWith('"') && cleaned.endsWith('"')) ||
            (cleaned.startsWith("'") && cleaned.endsWith("'")))) {
      cleaned = cleaned.substring(1, cleaned.length - 1).trim();
    }
    cleaned = cleaned.replaceAll('\r', '; ').replaceAll('\n', '; ');
    if (cleaned.isEmpty) return '';

    if (cleaned.toLowerCase().startsWith('cookie:')) {
      cleaned = cleaned.substring(7).trim();
    }

    final parts = [
      for (final seg in cleaned.split(';'))
        if (seg.trim().isNotEmpty) seg.trim(),
    ];
    if (parts.isEmpty) return '';

    final hasMusicU = parts.any((seg) {
      final eq = seg.indexOf('=');
      return eq > 0 && seg.substring(0, eq).trim().toUpperCase() == 'MUSIC_U';
    });
    if (!hasMusicU && !parts.first.contains('=')) {
      parts[0] = 'MUSIC_U=${parts.first}';
    }

    final hasOs = parts.any((seg) {
      final eq = seg.indexOf('=');
      return eq > 0 && seg.substring(0, eq).trim().toLowerCase() == 'os';
    });
    if (!hasOs) {
      parts.add('os=pc');
    }

    return parts.join('; ');
  }

  Directory? locateBackendDir() {
    if (!isDesktop) return null;
    final roots = <Directory>[
      Directory.current,
      File(Platform.resolvedExecutable).parent,
    ];
    final seen = <String>{};

    for (final start in roots) {
      var cur = start;
      for (var depth = 0; depth < 7; depth++) {
        final candidates = [
          Directory('${cur.path}${Platform.pathSeparator}backend'),
          Directory(
            '${cur.path}${Platform.pathSeparator}live-call-editor${Platform.pathSeparator}backend',
          ),
        ];
        for (final dir in candidates) {
          final norm = dir.path;
          if (!seen.add(norm)) continue;
          final mainPy = File(
            '${dir.path}${Platform.pathSeparator}app${Platform.pathSeparator}main.py',
          );
          if (dir.existsSync() && mainPy.existsSync()) {
            return dir;
          }
        }
        final parent = cur.parent;
        if (parent.path == cur.path) break;
        cur = parent;
      }
    }
    return null;
  }

  String? findPythonBinary(Directory backendDir) {
    final sep = Platform.pathSeparator;
    final candidates = [
      '${backendDir.path}$sep.venv${sep}Scripts${sep}python.exe',
      '${backendDir.path}$sep.venv${sep}bin${sep}python',
      '${backendDir.path}$sep.venv${sep}bin${sep}python3',
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return Platform.isWindows ? 'python' : 'python3';
  }

  String? findNodeBinary() {
    final candidates = [
      if (Platform.isWindows) r'C:\Program Files\nodejs\node.exe',
      if (Platform.isWindows) r'C:\Program Files (x86)\nodejs\node.exe',
      '/usr/local/bin/node',
      '/opt/homebrew/bin/node',
      '/usr/bin/node',
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return 'node';
  }

  String? findNcmApiEntry({Directory? backendDir}) {
    final sep = Platform.pathSeparator;
    final relSuffix =
        '@neteasecloudmusicapienhanced${sep}api${sep}app.js';
    final candidates = <String>[
      if (backendDir != null)
        '${backendDir.parent.path}${sep}netease-gateway${sep}node_modules$sep$relSuffix',
      if (backendDir != null)
        '${backendDir.path}${sep}node_modules$sep$relSuffix',
    ];

    final appData = Platform.environment['APPDATA'];
    if (appData != null && appData.isNotEmpty) {
      candidates.add('$appData${sep}npm${sep}node_modules$sep$relSuffix');
    }
    final userProfile =
        Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
    if (userProfile != null && userProfile.isNotEmpty) {
      candidates.add(
        '$userProfile${sep}AppData${sep}Roaming${sep}npm${sep}node_modules$sep$relSuffix',
      );
      candidates.add('$userProfile$sep.npm-global${sep}lib${sep}node_modules$sep$relSuffix');
    }
    candidates.add('/usr/local/lib/node_modules/$relSuffix');
    candidates.add('/usr/lib/node_modules/$relSuffix');

    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  Future<void> writeEnvConfig(
    Directory backendDir, {
    required String gatewayUrl,
    String cookie = '',
  }) async {
    final envFile = File(
      '${backendDir.path}${Platform.pathSeparator}.env',
    );
    List<String> existing;
    if (await envFile.exists()) {
      existing = (await envFile.readAsString()).split(RegExp(r'\r?\n'));
    } else {
      existing = [
        'MUSIC_API_BASE_URL=http://127.0.0.1:3000',
        'NETEASE_COOKIE=',
        'MUSIC_API_TOKEN=',
        'MUSIC_SEARCH_PATH=/search',
        'MUSIC_LYRIC_PATH=/lyric',
        'MUSIC_URL_PATH=/song/url',
        'LRCLIB_BASE_URL=https://lrclib.net',
        'ALLOWED_ORIGINS=http://localhost:5173,http://127.0.0.1:5173,http://localhost:4173',
        'HTTP_TIMEOUT_SECONDS=10',
      ];
    }

    final updates = <String, String>{
      'MUSIC_API_BASE_URL': normalizeGatewayUrl(gatewayUrl),
      if (cookie.trim().isNotEmpty)
        'NETEASE_COOKIE': normalizeNeteaseCookie(cookie),
    };

    final remaining = Map<String, String>.from(updates);
    final out = <String>[];
    for (final line in existing) {
      final trimmed = line.trim();
      if (trimmed.isEmpty && identical(line, existing.last)) continue;
      if (trimmed.isEmpty || trimmed.startsWith('#') || !line.contains('=')) {
        out.add(line);
        continue;
      }
      final idx = line.indexOf('=');
      final key = line.substring(0, idx).trim();
      if (remaining.containsKey(key)) {
        out.add('$key=${remaining.remove(key)}');
      } else {
        out.add(line);
      }
    }
    for (final entry in remaining.entries) {
      out.add('${entry.key}=${entry.value}');
    }
    await envFile.writeAsString('${out.join('\n')}\n');
  }

  Future<bool> isHttpReachable(String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return false;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final req = await client.getUrl(uri).timeout(const Duration(seconds: 2));
      final resp = await req.close().timeout(const Duration(seconds: 2));
      await resp.drain<void>();
      return resp.statusCode < 500;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<({bool ok, String message})> ensureBackendRunning(
    String backendUrl,
  ) async {
    if (!isDesktop) {
      return (ok: false, message: '仅桌面端支持本地自动拉起后端进程');
    }
    final clean = backendUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (await isHttpReachable('$clean/health')) {
      return (ok: true, message: 'FastAPI 后端已在线');
    }
    if (!isLoopbackUrl(clean)) {
      return (ok: false, message: '远程后端 $clean 不可达，无法从本机拉起');
    }
    final backendDir = locateBackendDir();
    if (backendDir == null) {
      return (ok: false, message: '未找到本地 backend 目录，请确认后端地址');
    }
    final pyBin = findPythonBinary(backendDir)!;
    final port = extractPort(clean, fallback: 8000);
    try {
      await Process.start(
        pyBin,
        ['-m', 'uvicorn', 'app.main:app', '--host', '127.0.0.1', '--port', '$port'],
        workingDirectory: backendDir.path,
        mode: ProcessStartMode.detached,
      );
    } catch (err) {
      return (ok: false, message: '启动后端失败：$err');
    }

    for (var i = 0; i < 24; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (await isHttpReachable('$clean/health')) {
        return (ok: true, message: '已自动启动 FastAPI 后端 (:$port)');
      }
    }
    return (ok: false, message: '后端启动超时，请检查 Python 环境');
  }

  Future<({bool ok, String message})> ensureGatewayRunningDirectly(
    String gatewayUrl,
  ) async {
    if (!isDesktop) {
      return (ok: false, message: '移动端请确保 PC 端后端在线以代为拉起网关');
    }
    final clean = normalizeGatewayUrl(gatewayUrl);
    if (await isHttpReachable('$clean/search?keywords=test&limit=1')) {
      return (ok: true, message: '网易云网关已在运行 ($clean)');
    }
    if (!isLoopbackUrl(clean)) {
      return (ok: false, message: '远程网关 $clean 不可达');
    }
    final backendDir = locateBackendDir();
    final entry = findNcmApiEntry(backendDir: backendDir);
    if (entry == null) {
      return (
        ok: false,
        message: '未找到 @neteasecloudmusicapienhanced/api，请安装或确认 Node 环境',
      );
    }
    final nodeBin = findNodeBinary()!;
    final port = extractPort(clean, fallback: 3000);
    try {
      await Process.start(
        nodeBin,
        [entry],
        workingDirectory: File(entry).parent.path,
        environment: {
          ...Platform.environment,
          'PORT': '$port',
          'HOST': '127.0.0.1',
          'CORS_ALLOW_ORIGIN': '*',
        },
        mode: ProcessStartMode.detached,
      );
    } catch (err) {
      return (ok: false, message: '启动 Node 网关失败：$err');
    }

    for (var i = 0; i < 24; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (await isHttpReachable('$clean/search?keywords=test&limit=1')) {
        return (ok: true, message: '已在本地直接拉起网易云网关 (:$port)');
      }
    }
    return (ok: false, message: '网关启动超时，请检查 Node 与 3000 端口');
  }
}
