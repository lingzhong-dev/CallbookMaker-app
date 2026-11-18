import 'dart:ui' show Color;

/// Parses a user-entered idol support color from Hex or RGB notation.
///
/// Supported formats:
/// - Hex: `#RRGGBB`, `RRGGBB`, `#RGB`, `RGB`
/// - RGB: `102, 204, 255`, `102 204 255`, `rgb(102, 204, 255)`
///   (including full-width commas/parentheses).
Color? parseSupportColor(String input) {
  final raw = input
      .trim()
      .replaceAll('，', ',')
      .replaceAll('（', '(')
      .replaceAll('）', ')');
  if (raw.isEmpty) return null;

  // Hex (#RGB, RGB, #RRGGBB, RRGGBB)
  final hexCandidate = raw.startsWith('#') ? raw.substring(1).trim() : raw;
  if (RegExp(r'^[0-9A-Fa-f]{3}$').hasMatch(hexCandidate)) {
    final r = int.parse(hexCandidate[0] * 2, radix: 16);
    final g = int.parse(hexCandidate[1] * 2, radix: 16);
    final b = int.parse(hexCandidate[2] * 2, radix: 16);
    return Color.fromARGB(0xFF, r, g, b);
  }
  if (RegExp(r'^[0-9A-Fa-f]{6}$').hasMatch(hexCandidate)) {
    final rgb = int.parse(hexCandidate, radix: 16);
    return Color(0xFF000000 | rgb);
  }

  // RGB: rgb(r, g, b) or r, g, b or r g b
  final rgbWrapped = RegExp(
    r'^rgb\s*\(\s*([^)]+)\s*\)$',
    caseSensitive: false,
  ).firstMatch(raw);
  final rgbBody = rgbWrapped != null ? rgbWrapped.group(1)!.trim() : raw;

  final parts = rgbBody.contains(',')
      ? rgbBody.split(',').map((s) => s.trim()).toList()
      : rgbBody.split(RegExp(r'\s+')).map((s) => s.trim()).toList();
  if (parts.length != 3 || parts.any((p) => p.isEmpty)) {
    return null;
  }

  final channels = <int>[];
  for (final part in parts) {
    if (!RegExp(r'^\d+$').hasMatch(part)) return null;
    final val = int.tryParse(part);
    if (val == null || val < 0 || val > 255) return null;
    channels.add(val);
  }
  return Color.fromARGB(0xFF, channels[0], channels[1], channels[2]);
}

String formatHexColor(Color color) {
  final rgb = color.toARGB32() & 0x00FFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

String formatRgbColor(Color color) {
  final argb = color.toARGB32();
  final r = (argb >> 16) & 0xFF;
  final g = (argb >> 8) & 0xFF;
  final b = argb & 0xFF;
  return '$r, $g, $b';
}
