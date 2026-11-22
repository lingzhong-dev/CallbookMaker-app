import 'dart:typed_data';

import 'package:kuromoji_dart/src/dict/character_definition.dart';
import 'package:kuromoji_dart/src/dict/connection_costs.dart';
import 'package:kuromoji_dart/src/dict/double_array_trie.dart';
import 'package:kuromoji_dart/src/dict/token_info_dictionary.dart';
import 'package:kuromoji_dart/src/dict/unknown_dictionary.dart';
import 'package:kuromoji_dart/src/util/byte_buffer.dart';

class DynamicDictionaries {
  late final TokenInfoDictionary tokenInfoDictionary;
  late final UnknownDictionary unknownDictionary;
  late final ConnectionCosts connectionCosts;
  late final CharacterDefinition characterDefinition;
  late final DoubleArray trie;

  DynamicDictionaries(Map<String, Uint8List> data, Uint8List charDef) {
    tokenInfoDictionary = TokenInfoDictionary(
      ByteBuffer(data['tid.dat']!),
      ByteBuffer(data['tid_pos.dat']!),
      ByteBuffer(data['tid_map.dat']!),
    );
    unknownDictionary = UnknownDictionary(
      ByteBuffer(data['unk.dat']!),
      ByteBuffer(data['unk_pos.dat']!),
      ByteBuffer(data['unk_map.dat']!),
      ByteBuffer(data['unk_char.dat']!),
      ByteBuffer(data['unk_compat.dat']!),
      ByteBuffer(data['unk_invoke.dat']!),
    );
    connectionCosts = ConnectionCosts(ByteBuffer(data['cc.dat']!));
    characterDefinition = CharacterDefinition(ByteBuffer(charDef));
    final baseBytes = data['base.dat']!;
    final checkBytes = data['check.dat']!;
    trie = DoubleArrayTrie.load(
      Int32List.view(
        baseBytes.buffer,
        baseBytes.offsetInBytes,
        baseBytes.lengthInBytes ~/ 4,
      ),
      Int32List.view(
        checkBytes.buffer,
        checkBytes.offsetInBytes,
        checkBytes.lengthInBytes ~/ 4,
      ),
    );
  }
}
