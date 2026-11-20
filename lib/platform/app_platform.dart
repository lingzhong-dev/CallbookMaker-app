import 'dart:io' show Directory, File, Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// Centralized platform capability boundary for CallbookMaker.
///
/// Only **Android** and **Windows** are supported runtime platforms.
/// Unsupported platforms (Web, macOS, Linux, iOS) are isolated here so no
/// other file in `lib/` branches on them.
abstract final class AppPlatform {
  static bool get isWeb => kIsWeb;

  static bool get isAndroid => !kIsWeb && Platform.isAndroid;

  static bool get isWindows => !kIsWeb && Platform.isWindows;

  static bool get isSupported => isAndroid || isWindows;

  static bool get isWidgetTest =>
      !kIsWeb && Platform.environment.containsKey('FLUTTER_TEST');

  static String get pathSeparator => Platform.pathSeparator;

  static Map<String, String> get environment =>
      kIsWeb ? const {} : Platform.environment;

  static Directory? get executableDir =>
      kIsWeb ? null : File(Platform.resolvedExecutable).parent;
}
