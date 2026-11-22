import 'dart:typed_data';

import 'package:kuromoji_dart/src/dict/dynamic_dictionaries.dart';
import 'package:kuromoji_dart/src/dictionary_loader.dart';
import 'package:kuromoji_dart/src/token.dart';
import 'package:kuromoji_dart/src/viterbi/viterbi_builder.dart';
import 'package:kuromoji_dart/src/viterbi/viterbi_node.dart';
import 'package:kuromoji_dart/src/viterbi/viterbi_searcher.dart';

final _sentenceSplitPattern = RegExp(r'[、。]');

class Tokenizer {
  Tokenizer(this.dictionaries)
      : viterbiBuilder = ViterbiBuilder(dictionaries),
        viterbiSearcher = ViterbiSearcher(dictionaries.connectionCosts);

  final DynamicDictionaries dictionaries;
  final ViterbiBuilder viterbiBuilder;
  final ViterbiSearcher viterbiSearcher;

  /// Builds a [Tokenizer] from raw `.dat.gz` asset bytes and `char.def` bytes.
  /// Safe to invoke inside `Isolate.run`.
  factory Tokenizer.fromCompressedAssets({
    required Map<String, Uint8List> compressedFiles,
    required Uint8List charDef,
  }) {
    const loader = DictionaryLoader();
    final data = loader.decodeGzipped(compressedFiles);
    final dictionaries = DynamicDictionaries(data, charDef);
    return Tokenizer(dictionaries);
  }

  /// Builds a [Tokenizer] directly from an on-disk IPADIC directory (for tests).
  factory Tokenizer.fromDirectorySync(String dirPath) {
    final loaded = DictionaryLoader.readDirectorySync(dirPath);
    return Tokenizer.fromCompressedAssets(
      compressedFiles: loaded.compressed,
      charDef: loaded.charDef,
    );
  }

  List<KuromojiToken> tokenize(String text) {
    if (text.isEmpty) return const [];
    final sentences = _splitByPunctuation(text);
    final tokens = <KuromojiToken>[];
    var charOffset = 0;
    for (final sentence in sentences) {
      _tokenizeForSentence(sentence, charOffset, tokens);
      charOffset += sentence.length;
    }
    return tokens;
  }

  void _tokenizeForSentence(
    String sentence,
    int charOffset,
    List<KuromojiToken> tokens,
  ) {
    final lattice = viterbiBuilder.build(sentence);
    final bestPath = viterbiSearcher.search(lattice);
    for (final node in bestPath) {
      tokens.add(_formatNode(node, charOffset));
    }
  }

  KuromojiToken _formatNode(ViterbiNode node, int charOffset) {
    final featuresLine = node.type == 'KNOWN'
        ? dictionaries.tokenInfoDictionary.getFeatures(node.name)
        : dictionaries.unknownDictionary.getFeatures(node.name);
    final features = featuresLine?.split(',') ?? const <String>[];
    return KuromojiToken.fromFeatures(
      wordId: node.name,
      position: charOffset + node.startPos,
      type: node.type,
      features: features,
      surfaceForm: node.surfaceForm ?? (features.isNotEmpty ? features[0] : ''),
    );
  }

  List<String> _splitByPunctuation(String text) {
    final sentences = <String>[];
    var tail = text;
    while (tail.isNotEmpty) {
      final index = tail.indexOf(_sentenceSplitPattern);
      if (index < 0) {
        sentences.add(tail);
        break;
      }
      sentences.add(tail.substring(0, index + 1));
      tail = tail.substring(index + 1);
    }
    return sentences;
  }
}
