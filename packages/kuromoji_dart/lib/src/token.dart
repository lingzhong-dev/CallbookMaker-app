/// A single morphological token produced by [Tokenizer].
class KuromojiToken {
  const KuromojiToken({
    required this.wordId,
    required this.wordPosition,
    required this.wordType,
    required this.surfaceForm,
    required this.pos,
    required this.posDetails,
    required this.conjugatedType,
    required this.conjugatedForm,
    required this.basicForm,
    this.reading,
    this.pronunciation,
  });

  final int wordId;
  final int wordPosition;
  final String wordType;
  final String surfaceForm;
  final String pos;
  final (String, String, String) posDetails;
  final String conjugatedType;
  final String conjugatedForm;
  final String basicForm;
  final String? reading;
  final String? pronunciation;

  bool get isKnown => wordType == 'KNOWN';

  factory KuromojiToken.fromFeatures({
    required int wordId,
    required int position,
    required String type,
    required List<String> features,
    required String surfaceForm,
  }) {
    String field(int idx) =>
        idx < features.length && features[idx].isNotEmpty ? features[idx] : '*';

    String? optionalField(int idx) {
      if (idx >= features.length) return null;
      final v = features[idx].trim();
      if (v.isEmpty || v == '*') return null;
      return v;
    }

    return KuromojiToken(
      wordId: wordId,
      wordPosition: position,
      wordType: type,
      surfaceForm: surfaceForm,
      pos: field(1),
      posDetails: (field(2), field(3), field(4)),
      conjugatedType: field(5),
      conjugatedForm: field(6),
      basicForm: field(7),
      reading: optionalField(8),
      pronunciation: optionalField(9),
    );
  }
}
