import 'dart:io' show File, Platform;
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

const int kMaxPngExportWidth = 4096;
const int kMaxPngExportHeight = 16384;
const int kMaxPngExportPixels = kMaxPngExportWidth * kMaxPngExportHeight;

/// Computes a safe PNG export pixelRatio bounded by width, height, and total
/// pixel count (`width * height * pixelRatio^2 <= maxPixels`).
double computeSafePngPixelRatio({
  required double logicalWidth,
  required double logicalHeight,
  double preferredRatio = 2.5,
  int maxWidth = kMaxPngExportWidth,
  int maxHeight = kMaxPngExportHeight,
  int maxPixels = kMaxPngExportPixels,
}) {
  if (logicalWidth <= 0 || logicalHeight <= 0 || preferredRatio <= 0) {
    return preferredRatio > 0 ? preferredRatio : 1.0;
  }
  var ratio = preferredRatio;
  final widthCap = maxWidth / logicalWidth;
  final heightCap = maxHeight / logicalHeight;
  final areaCap = math.sqrt(maxPixels / (logicalWidth * logicalHeight));
  ratio = math.min(ratio, widthCap);
  ratio = math.min(ratio, heightCap);
  ratio = math.min(ratio, areaCap);
  return ratio.clamp(0.25, preferredRatio).toDouble();
}

class SaveBytesResult {
  const SaveBytesResult({
    required this.cancelled,
    this.savedPath,
    this.usedFallback = false,
  });

  final bool cancelled;
  final String? savedPath;
  final bool usedFallback;
}

typedef SaveFilePickerFn = Future<String?> Function({
  required String dialogTitle,
  required String fileName,
  required List<String> allowedExtensions,
  Uint8List? bytes,
  bool lockParentWindow,
});

typedef WriteBytesFn = Future<void> Function(String path, Uint8List bytes);
typedef TempDirPathFn = Future<String> Function();
typedef ShareFileFn = Future<void> Function(String path, String? text);

Future<String?> _defaultSaveFilePicker({
  required String dialogTitle,
  required String fileName,
  required List<String> allowedExtensions,
  Uint8List? bytes,
  bool lockParentWindow = false,
}) {
  return FilePicker.platform.saveFile(
    dialogTitle: dialogTitle,
    fileName: fileName,
    type: FileType.custom,
    allowedExtensions: allowedExtensions,
    bytes: bytes,
    lockParentWindow: lockParentWindow,
  );
}

Future<void> _defaultWriteBytes(String path, Uint8List bytes) async {
  await File(path).writeAsBytes(bytes, flush: true);
}

Future<String> _defaultTempDirPath() async {
  final dir = await getTemporaryDirectory();
  return dir.path;
}

Future<void> _defaultShareFile(String path, String? text) async {
  await Share.shareXFiles([XFile(path)], text: text);
}

String _ensureFileExtension(String rawPath, List<String> allowedExtensions) {
  final trimmed = rawPath.trim();
  if (allowedExtensions.isEmpty) return trimmed;
  final lower = trimmed.toLowerCase();
  for (final ext in allowedExtensions) {
    final normalized = ext.startsWith('.') ? ext.toLowerCase() : '.${ext.toLowerCase()}';
    if (lower.endsWith(normalized)) {
      return trimmed;
    }
  }
  final primary = allowedExtensions.first;
  final suffix = primary.startsWith('.') ? primary : '.$primary';
  return '$trimmed$suffix';
}

/// Saves [bytes] to a user-chosen location across platforms (Android / Windows),
/// falling back to a temporary file + share sheet if the native picker fails.
Future<SaveBytesResult> saveBytesToUserLocation({
  required Uint8List bytes,
  required String fileName,
  required String dialogTitle,
  required List<String> allowedExtensions,
  String? shareText,
  SaveFilePickerFn? saveFilePicker,
  WriteBytesFn? writeFile,
  TempDirPathFn? getTempDirPath,
  ShareFileFn? shareFile,
  bool? isWebOverride,
  bool? isMobileOverride,
  bool? isDesktopOverride,
  bool? isWidgetTestOverride,
}) async {
  final picker = saveFilePicker ?? _defaultSaveFilePicker;
  final writer = writeFile ?? _defaultWriteBytes;
  final tempDirFn = getTempDirPath ?? _defaultTempDirPath;
  final sharer = shareFile ?? _defaultShareFile;

  final isWeb = isWebOverride ?? kIsWeb;
  final isWidgetTest = isWidgetTestOverride ??
      (!isWeb &&
          saveFilePicker == null &&
          Platform.environment.containsKey('FLUTTER_TEST'));

  if (isWeb) {
    await picker(
      dialogTitle: dialogTitle,
      fileName: fileName,
      allowedExtensions: allowedExtensions,
      bytes: bytes,
      lockParentWindow: false,
    );
    return SaveBytesResult(cancelled: false, savedPath: fileName);
  }

  final isMobile = isMobileOverride ?? (Platform.isAndroid || Platform.isIOS);
  final isDesktop = isDesktopOverride ??
      (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  if (!isWidgetTest && isMobile) {
    try {
      final saved = await picker(
        dialogTitle: dialogTitle,
        fileName: fileName,
        allowedExtensions: allowedExtensions,
        bytes: bytes,
        lockParentWindow: false,
      );
      if (saved == null) {
        return const SaveBytesResult(cancelled: true);
      }
      return SaveBytesResult(
        cancelled: false,
        savedPath: saved.trim().isNotEmpty ? saved.trim() : fileName,
      );
    } catch (_) {
      // Fall through to temp directory + share sheet fallback.
    }
  } else if (!isWidgetTest && isDesktop) {
    try {
      final pickedPath = await picker(
        dialogTitle: dialogTitle,
        fileName: fileName,
        allowedExtensions: allowedExtensions,
        lockParentWindow: true,
      );
      if (pickedPath == null) {
        return const SaveBytesResult(cancelled: true);
      }
      if (pickedPath.trim().isNotEmpty) {
        final targetPath = _ensureFileExtension(pickedPath, allowedExtensions);
        await writer(targetPath, bytes);
        return SaveBytesResult(cancelled: false, savedPath: targetPath);
      }
    } catch (_) {
      // Fall through to temp directory fallback.
    }
  }

  final dirPath = await tempDirFn();
  final outPath = '$dirPath${Platform.pathSeparator}$fileName';
  await writer(outPath, bytes);
  try {
    await sharer(outPath, shareText);
  } catch (_) {
    // Headless / desktop environments without share sheet keep written file.
  }
  return SaveBytesResult(
    cancelled: false,
    savedPath: outPath,
    usedFallback: true,
  );
}
