/// Pure-Dart helpers for normalizing and masking Netease Cloud Music cookies.
String normalizeNeteaseCookie(String raw) {
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

/// Masks sensitive `MUSIC_U` token values for safe UI display.
String maskNeteaseCookie(String rawCookie) {
  final norm = normalizeNeteaseCookie(rawCookie);
  if (norm.isEmpty) return '';
  for (final seg in norm.split(';')) {
    final trimmed = seg.trim();
    final eq = trimmed.indexOf('=');
    if (eq > 0 &&
        trimmed.substring(0, eq).trim().toUpperCase() == 'MUSIC_U') {
      final val = trimmed.substring(eq + 1).trim();
      if (val.length <= 10) return 'MUSIC_U=***';
      return 'MUSIC_U=${val.substring(0, 4)}***${val.substring(val.length - 4)}';
    }
  }
  if (norm.length <= 10) return '***';
  return '${norm.substring(0, 4)}***${norm.substring(norm.length - 4)}';
}
