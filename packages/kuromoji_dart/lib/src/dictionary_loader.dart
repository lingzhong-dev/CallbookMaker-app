import 'dart:io';
import 'dart:typed_data';

/// Standard IPADIC binary assets required to build a [Tokenizer].
abstract final class KuromojiAssetNames {
  static const List<String> gzippedFiles = [
    'base.dat.gz',
    'cc.dat.gz',
    'check.dat.gz',
    'tid.dat.gz',
    'tid_map.dat.gz',
    'tid_pos.dat.gz',
    'unk.dat.gz',
    'unk_char.dat.gz',
    'unk_compat.dat.gz',
    'unk_invoke.dat.gz',
    'unk_map.dat.gz',
    'unk_pos.dat.gz',
  ];

  static const String charDefFile = 'char.def';

  static const String packageAssetPrefix = 'packages/kuromoji_dart/assets/dict';
}

/// Decodes raw gzipped IPADIC dictionary buffers using native `dart:io` gzip.
class DictionaryLoader {
  const DictionaryLoader();

  /// [compressedFiles] maps each filename in [KuromojiAssetNames.gzippedFiles]
  /// (e.g. `'base.dat.gz'`) to its raw `.gz` bytes.
  Map<String, Uint8List> decodeGzipped(Map<String, Uint8List> compressedFiles) {
    final result = <String, Uint8List>{};
    for (final gzName in KuromojiAssetNames.gzippedFiles) {
      final raw = compressedFiles[gzName];
      if (raw == null) {
        throw StateError('Missing kuromoji dictionary asset: $gzName');
      }
      final key = gzName.substring(0, gzName.length - 3); // strip '.gz'
      final decoded = gzip.decode(raw);
      result[key] = decoded is Uint8List ? decoded : Uint8List.fromList(decoded);
    }
    return result;
  }

  /// Loads raw compressed assets directly from a local directory on disk
  /// (useful for unit tests and CLI tooling).
  static ({Map<String, Uint8List> compressed, Uint8List charDef})
      readDirectorySync(String dirPath) {
    final sep = Platform.pathSeparator;
    final cleanDir = dirPath.endsWith(sep)
        ? dirPath.substring(0, dirPath.length - 1)
        : dirPath;
    final compressed = <String, Uint8List>{};
    for (final name in KuromojiAssetNames.gzippedFiles) {
      compressed[name] = File('$cleanDir$sep$name').readAsBytesSync();
    }
    final charDef =
        File('$cleanDir$sep${KuromojiAssetNames.charDefFile}').readAsBytesSync();
    return (compressed: compressed, charDef: charDef);
  }
}
