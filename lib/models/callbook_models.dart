import 'dart:convert';
import 'dart:ui';

enum CallCategory { downbeat, upbeat, build, compound }

enum LyricLineKind { lyric, intro, interlude, outro }

extension LyricLineKindExt on LyricLineKind {
  bool get isSection => this != LyricLineKind.lyric;

  String get zhLabel => switch (this) {
    LyricLineKind.intro => '前奏',
    LyricLineKind.interlude => '间奏',
    LyricLineKind.outro => '尾奏',
    LyricLineKind.lyric => '歌词',
  };

  String get bracketTitle => switch (this) {
    LyricLineKind.intro => '【前奏】',
    LyricLineKind.interlude => '【间奏】',
    LyricLineKind.outro => '【尾奏】',
    LyricLineKind.lyric => '',
  };

  static LyricLineKind fromJson(String? raw) => switch (raw) {
    'intro' => LyricLineKind.intro,
    'interlude' => LyricLineKind.interlude,
    'outro' => LyricLineKind.outro,
    _ => LyricLineKind.lyric,
  };
}

class SectionDetectThresholds {
  const SectionDetectThresholds({
    this.introThresholdMs = 6000,
    this.interludeThresholdMs = 8000,
    this.outroThresholdMs = 8000,
  });

  final int introThresholdMs;
  final int interludeThresholdMs;
  final int outroThresholdMs;

  SectionDetectThresholds copyWith({
    int? introThresholdMs,
    int? interludeThresholdMs,
    int? outroThresholdMs,
  }) => SectionDetectThresholds(
    introThresholdMs: introThresholdMs ?? this.introThresholdMs,
    interludeThresholdMs: interludeThresholdMs ?? this.interludeThresholdMs,
    outroThresholdMs: outroThresholdMs ?? this.outroThresholdMs,
  );
}

extension CallCategoryLabel on CallCategory {
  String get zhLabel => switch (this) {
    CallCategory.downbeat => '正拍',
    CallCategory.upbeat => '反拍 / 里拍',
    CallCategory.build => '推升 / 过渡',
    CallCategory.compound => '复合动作',
  };

  static CallCategory fromJson(String? raw) => switch (raw) {
    'downbeat' => CallCategory.downbeat,
    'upbeat' => CallCategory.upbeat,
    'build' => CallCategory.build,
    _ => CallCategory.compound,
  };
}

class CallPreset {
  const CallPreset({
    required this.id,
    required this.label,
    required this.colorHex,
    required this.category,
    required this.shortcut,
    this.builtIn = false,
  });

  final String id;
  final String label;
  final String colorHex;
  final CallCategory category;
  final String shortcut;
  final bool builtIn;

  Color get color {
    final cleaned = colorHex.replaceFirst('#', '').trim();
    if (cleaned.length == 6) {
      return Color(int.parse('FF$cleaned', radix: 16));
    }
    if (cleaned.length == 8) {
      return Color(int.parse(cleaned, radix: 16));
    }
    return const Color(0xFF0061FF);
  }

  CallPreset copyWith({
    String? id,
    String? label,
    String? colorHex,
    CallCategory? category,
    String? shortcut,
    bool? builtIn,
  }) => CallPreset(
    id: id ?? this.id,
    label: label ?? this.label,
    colorHex: colorHex ?? this.colorHex,
    category: category ?? this.category,
    shortcut: shortcut ?? this.shortcut,
    builtIn: builtIn ?? this.builtIn,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'color': colorHex,
    'category': category.name,
    'shortcut': shortcut,
    'builtIn': builtIn,
  };

  factory CallPreset.fromJson(Map<String, dynamic> json) => CallPreset(
    id: json['id']?.toString() ?? 'custom-${DateTime.now().millisecondsSinceEpoch}',
    label: json['label']?.toString() ?? 'Call',
    colorHex: json['color']?.toString() ?? '#0061FF',
    category: CallCategoryLabel.fromJson(json['category']?.toString()),
    shortcut: json['shortcut']?.toString() ?? '',
    builtIn: json['builtIn'] == true,
  );
}

const String singAlongPresetId = 'sing-along';

const List<CallPreset> defaultCallPresets = [
  CallPreset(
    id: 'front-wave',
    label: '前挥',
    colorHex: '#EF4444',
    category: CallCategory.downbeat,
    shortcut: '1',
    builtIn: true,
  ),
  CallPreset(
    id: 'flat-chop',
    label: '平敲',
    colorHex: '#F59E0B',
    category: CallCategory.downbeat,
    shortcut: '2',
    builtIn: true,
  ),
  CallPreset(
    id: 'updraft',
    label: '上升气流',
    colorHex: '#8B5CF6',
    category: CallCategory.build,
    shortcut: '3',
    builtIn: true,
  ),
  CallPreset(
    id: 'wiper',
    label: '雨刷',
    colorHex: '#06B6D4',
    category: CallCategory.compound,
    shortcut: '4',
    builtIn: true,
  ),
  CallPreset(
    id: 'ura-uchi',
    label: '里打',
    colorHex: '#10B981',
    category: CallCategory.upbeat,
    shortcut: '5',
    builtIn: true,
  ),
  CallPreset(
    id: 'ura-uchi-hai',
    label: '里打hai',
    colorHex: '#059669',
    category: CallCategory.upbeat,
    shortcut: '6',
    builtIn: true,
  ),
  CallPreset(
    id: 'ura-jump',
    label: '里跳',
    colorHex: '#16A34A',
    category: CallCategory.upbeat,
    shortcut: '7',
    builtIn: true,
  ),
  CallPreset(
    id: 'ppph',
    label: 'PPPH',
    colorHex: '#2563EB',
    category: CallCategory.build,
    shortcut: '8',
    builtIn: true,
  ),
  CallPreset(
    id: 'sing-along',
    label: '跟唱',
    colorHex: '#EC4899',
    category: CallCategory.compound,
    shortcut: '9',
    builtIn: true,
  ),
  CallPreset(
    id: 'clap',
    label: '拍手',
    colorHex: '#14B8A6',
    category: CallCategory.downbeat,
    shortcut: '0',
    builtIn: true,
  ),
];

class LineCallTag {
  const LineCallTag({required this.presetId, this.suffix});

  final String presetId;
  final String? suffix;

  LineCallTag copyWith({String? presetId, String? suffix}) => LineCallTag(
    presetId: presetId ?? this.presetId,
    suffix: suffix ?? this.suffix,
  );

  Map<String, dynamic> toJson() => {
    'presetId': presetId,
    if (suffix != null && suffix!.isNotEmpty) 'suffix': suffix,
  };

  factory LineCallTag.fromJson(Map<String, dynamic> json) => LineCallTag(
    presetId: json['presetId']?.toString() ?? '',
    suffix: json['suffix']?.toString(),
  );
}

class GtAlert {
  const GtAlert({
    required this.id,
    required this.triggerTimeMs,
    this.leadBeats = 4,
    this.note = '',
    this.targetLineId,
    this.callTimingCue,
  });

  final String id;
  final int triggerTimeMs;
  final int leadBeats;
  final String note;
  final String? targetLineId;
  final String? callTimingCue;

  GtAlert copyWith({
    String? id,
    int? triggerTimeMs,
    int? leadBeats,
    String? note,
    String? targetLineId,
    bool clearTargetLineId = false,
    String? callTimingCue,
    bool clearCallTimingCue = false,
  }) => GtAlert(
    id: id ?? this.id,
    triggerTimeMs: triggerTimeMs ?? this.triggerTimeMs,
    leadBeats: leadBeats ?? this.leadBeats,
    note: note ?? this.note,
    targetLineId: clearTargetLineId ? null : (targetLineId ?? this.targetLineId),
    callTimingCue: clearCallTimingCue
        ? null
        : (callTimingCue ?? this.callTimingCue),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'triggerTimeMs': triggerTimeMs,
    'leadBeats': leadBeats,
    'note': note,
    if (targetLineId != null && targetLineId!.trim().isNotEmpty)
      'targetLineId': targetLineId,
    if (callTimingCue != null && callTimingCue!.trim().isNotEmpty)
      'callTimingCue': callTimingCue,
  };

  factory GtAlert.fromJson(Map<String, dynamic> json) {
    final rawTarget = json['targetLineId']?.toString().trim();
    final rawCue = json['callTimingCue']?.toString();
    return GtAlert(
      id: json['id']?.toString() ?? 'gt-${DateTime.now().millisecondsSinceEpoch}',
      triggerTimeMs: (json['triggerTimeMs'] as num?)?.round() ?? 0,
      leadBeats: (json['leadBeats'] as num?)?.round() ?? 4,
      note: json['note']?.toString() ?? '',
      targetLineId: (rawTarget == null || rawTarget.isEmpty) ? null : rawTarget,
      callTimingCue: rawCue,
    );
  }
}

/// Resolves which lyric line a [GtAlert] binds to, falling back to nearest / next
/// line by `triggerTimeMs` for legacy JSON imports that omit `targetLineId`.
String? resolveGtAlertTargetLineId(
  GtAlert alert,
  List<LyricLine> orderedLines,
) {
  if (orderedLines.isEmpty) return null;
  final explicitId = alert.targetLineId?.trim();
  if (explicitId != null && explicitId.isNotEmpty) {
    for (final line in orderedLines) {
      if (line.id == explicitId) return line.id;
    }
  }
  LyricLine best = orderedLines.first;
  var bestDiff = (best.startTimeMs - alert.triggerTimeMs).abs();
  for (final line in orderedLines.skip(1)) {
    final diff = (line.startTimeMs - alert.triggerTimeMs).abs();
    if (diff < bestDiff ||
        (diff == bestDiff &&
            line.startTimeMs >= alert.triggerTimeMs &&
            best.startTimeMs < alert.triggerTimeMs)) {
      best = line;
      bestDiff = diff;
    }
  }
  return best.id;
}

class LyricText {
  const LyricText({
    required this.original,
    this.ruby,
    this.romaji,
    this.translation,
  });

  final String original;
  final String? ruby;
  final String? romaji;
  final String? translation;

  LyricText copyWith({
    String? original,
    String? ruby,
    String? romaji,
    String? translation,
  }) => LyricText(
    original: original ?? this.original,
    ruby: ruby ?? this.ruby,
    romaji: romaji ?? this.romaji,
    translation: translation ?? this.translation,
  );

  Map<String, dynamic> toJson() => {
    'original': original,
    if (ruby != null) 'ruby': ruby,
    if (romaji != null) 'romaji': romaji,
    if (translation != null) 'translation': translation,
  };

  factory LyricText.fromJson(Map<String, dynamic> json) => LyricText(
    original: json['original']?.toString() ?? '',
    ruby: json['ruby']?.toString(),
    romaji: json['romaji']?.toString(),
    translation: json['translation']?.toString(),
  );
}

class LyricLine {
  const LyricLine({
    required this.id,
    required this.startTimeMs,
    required this.endTimeMs,
    this.kind = LyricLineKind.lyric,
    this.autoGenerated = false,
    this.calls = const [],
    this.customShout = '',
    this.tailUpdraft = false,
    required this.text,
  });

  final String id;
  final int startTimeMs;
  final int endTimeMs;
  final LyricLineKind kind;
  final bool autoGenerated;
  final List<LineCallTag> calls;
  final String customShout;
  final bool tailUpdraft;
  final LyricText text;

  LyricLine copyWith({
    String? id,
    int? startTimeMs,
    int? endTimeMs,
    LyricLineKind? kind,
    bool? autoGenerated,
    List<LineCallTag>? calls,
    String? customShout,
    bool? tailUpdraft,
    LyricText? text,
  }) => LyricLine(
    id: id ?? this.id,
    startTimeMs: startTimeMs ?? this.startTimeMs,
    endTimeMs: endTimeMs ?? this.endTimeMs,
    kind: kind ?? this.kind,
    autoGenerated: autoGenerated ?? this.autoGenerated,
    calls: calls ?? this.calls,
    customShout: customShout ?? this.customShout,
    tailUpdraft: tailUpdraft ?? this.tailUpdraft,
    text: text ?? this.text,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'startTimeMs': startTimeMs,
    'endTimeMs': endTimeMs,
    'kind': kind.name,
    'autoGenerated': autoGenerated,
    'calls': [for (final c in calls) c.toJson()],
    'customShout': customShout,
    if (tailUpdraft) 'tailUpdraft': true,
    'text': text.toJson(),
  };

  factory LyricLine.fromJson(Map<String, dynamic> json) {
    final rawCalls = json['calls'] as List<dynamic>? ?? const [];
    return LyricLine(
      id: json['id']?.toString() ?? 'line-${DateTime.now().millisecondsSinceEpoch}',
      startTimeMs: (json['startTimeMs'] as num?)?.round() ?? 0,
      endTimeMs: (json['endTimeMs'] as num?)?.round() ?? 3000,
      kind: LyricLineKindExt.fromJson(json['kind']?.toString()),
      autoGenerated: json['autoGenerated'] == true,
      calls: [
        for (final item in rawCalls)
          if (item is Map<String, dynamic>) LineCallTag.fromJson(item),
      ],
      customShout: json['customShout']?.toString() ?? '',
      tailUpdraft: json['tailUpdraft'] == true,
      text: LyricText.fromJson(
        (json['text'] as Map<String, dynamic>?) ?? const {},
      ),
    );
  }
}

class CallProjectMeta {
  const CallProjectMeta({
    required this.title,
    required this.artist,
    this.platform = 'synthetic',
    this.trackId,
    this.audioUrl = '',
    this.bpm = 175,
    this.timeSignature = '4/4',
    this.offsetMs = 0,
    this.composer = '',
    this.lyricist = '',
    this.vocalist = '',
    this.tuner = '',
    this.showTuner = false,
    this.editorName = '',
    this.editorNote = '',
  });

  final String title;
  final String artist;
  final String platform;
  final String? trackId;
  final String audioUrl;
  final int bpm;
  final String timeSignature;
  final int offsetMs;
  final String composer;
  final String lyricist;
  final String vocalist;
  final String tuner;
  final bool showTuner;
  final String editorName;
  final String editorNote;

  int get beatsPerBar => timeSignature == '3/4' ? 3 : 4;

  CallProjectMeta copyWith({
    String? title,
    String? artist,
    String? platform,
    String? trackId,
    String? audioUrl,
    int? bpm,
    String? timeSignature,
    int? offsetMs,
    String? composer,
    String? lyricist,
    String? vocalist,
    String? tuner,
    bool? showTuner,
    String? editorName,
    String? editorNote,
  }) => CallProjectMeta(
    title: title ?? this.title,
    artist: artist ?? this.artist,
    platform: platform ?? this.platform,
    trackId: trackId ?? this.trackId,
    audioUrl: audioUrl ?? this.audioUrl,
    bpm: bpm ?? this.bpm,
    timeSignature: timeSignature ?? this.timeSignature,
    offsetMs: offsetMs ?? this.offsetMs,
    composer: composer ?? this.composer,
    lyricist: lyricist ?? this.lyricist,
    vocalist: vocalist ?? this.vocalist,
    tuner: tuner ?? this.tuner,
    showTuner: showTuner ?? this.showTuner,
    editorName: editorName ?? this.editorName,
    editorNote: editorNote ?? this.editorNote,
  );

  Map<String, dynamic> toJson() => {
    'title': title,
    'artist': artist,
    'platform': platform,
    if (trackId != null) 'trackId': trackId,
    'audioUrl': audioUrl,
    'bpm': bpm,
    'timeSignature': timeSignature,
    'offsetMs': offsetMs,
    'composer': composer,
    'lyricist': lyricist,
    'vocalist': vocalist,
    'tuner': tuner,
    'showTuner': showTuner,
    'editorName': editorName,
    'editorNote': editorNote,
  };

  factory CallProjectMeta.fromJson(Map<String, dynamic> json) => CallProjectMeta(
    title: json['title']?.toString() ?? 'Untitled Live Call',
    artist: json['artist']?.toString() ?? '',
    platform: json['platform']?.toString() ?? 'synthetic',
    trackId: json['trackId']?.toString(),
    audioUrl: json['audioUrl']?.toString() ?? '',
    bpm: ((json['bpm'] as num?)?.round() ?? 128).clamp(30, 300),
    timeSignature: json['timeSignature'] == '3/4' ? '3/4' : '4/4',
    offsetMs: (json['offsetMs'] as num?)?.round() ?? 0,
    composer: json['composer']?.toString() ?? '',
    lyricist: json['lyricist']?.toString() ?? '',
    vocalist: json['vocalist']?.toString() ?? '',
    tuner: json['tuner']?.toString() ?? '',
    showTuner: json['showTuner'] == true,
    editorName: json['editorName']?.toString() ?? '',
    editorNote: json['editorNote']?.toString() ?? '',
  );
}

class CallProject {
  const CallProject({
    required this.meta,
    this.alerts = const [],
    this.lines = const [],
  });

  final CallProjectMeta meta;
  final List<GtAlert> alerts;
  final List<LyricLine> lines;

  CallProject copyWith({
    CallProjectMeta? meta,
    List<GtAlert>? alerts,
    List<LyricLine>? lines,
  }) => CallProject(
    meta: meta ?? this.meta,
    alerts: alerts ?? this.alerts,
    lines: lines ?? this.lines,
  );

  String toPrettyJson() => const JsonEncoder.withIndent('  ').convert(toJson());

  Map<String, dynamic> toJson() => {
    'meta': meta.toJson(),
    'alerts': [for (final a in alerts) a.toJson()],
    'lines': [for (final l in lines) l.toJson()],
  };

  factory CallProject.fromJson(Map<String, dynamic> json) {
    final rawAlerts = json['alerts'] as List<dynamic>? ?? const [];
    final rawLines = json['lines'] as List<dynamic>? ?? const [];
    return CallProject(
      meta: CallProjectMeta.fromJson(
        (json['meta'] as Map<String, dynamic>?) ?? const {},
      ),
      alerts: [
        for (final a in rawAlerts)
          if (a is Map<String, dynamic>) GtAlert.fromJson(a),
      ],
      lines: [
        for (final l in rawLines)
          if (l is Map<String, dynamic>) LyricLine.fromJson(l),
      ],
    );
  }

  factory CallProject.demo() => const CallProject(
    meta: CallProjectMeta(
      title: 'Starlight Overdrive (175 BPM 合成演练 Demo)',
      artist: 'Synthetic Stage Unit · 无版权测试音轨',
      platform: 'synthetic',
      trackId: 'demo-starlight-175',
      audioUrl: '',
      bpm: 175,
      timeSignature: '4/4',
      offsetMs: 0,
      composer: 'SAWTOWNE',
      lyricist: 'SAWTOWNE',
      vocalist: '初音ミク',
      tuner: '',
      showTuner: false,
      editorName: '',
      editorNote: '',
    ),
    alerts: [
      GtAlert(
        id: 'gt-demo-1',
        triggerTimeMs: 9600,
        leadBeats: 4,
        note: '吉他进场，4拍后进 PPPH',
        targetLineId: 'demo-4',
        callTimingCue: 'se-no',
      ),
      GtAlert(
        id: 'gt-demo-2',
        triggerTimeMs: 17820,
        leadBeats: 4,
        note: '副歌爆发段！准备全员前挥 ×4',
        targetLineId: 'demo-7',
        callTimingCue: 'hi hi hihihihi',
      ),
    ],
    lines: [
      LyricLine(
        id: 'demo-1',
        startTimeMs: 1370,
        endTimeMs: 4110,
        calls: [LineCallTag(presetId: 'ura-uchi', suffix: '×4')],
        customShout: 'タイガー！ファイヤー！',
        text: LyricText(
          original: '夜空を見上げて 響けメロディ',
          ruby:
              '<ruby>夜空<rt>よぞら</rt></ruby>を<ruby>見上<rt>みあ</rt></ruby>げて <ruby>響<rt>ひび</rt></ruby>けメロディ',
          romaji: 'Yozora wo miagete hibike merodi',
          translation: '仰望夜空 让旋律回响吧',
        ),
      ),
      LyricLine(
        id: 'demo-2',
        startTimeMs: 4110,
        endTimeMs: 6850,
        calls: [LineCallTag(presetId: 'ura-uchi-hai', suffix: '×4')],
        customShout: 'サイバー！ファイバー！',
        text: LyricText(
          original: '高鳴る鼓動が 今 始まる',
          ruby:
              '<ruby>高鳴<rt>たかな</rt></ruby>る<ruby>鼓動<rt>こどう</rt></ruby>が <ruby>今<rt>いま</rt></ruby> <ruby>始<rt>はじ</rt></ruby>まる',
          romaji: 'Takanaru kodou ga ima hajimaru',
          translation: '沸腾的心跳 此刻正式开启',
        ),
      ),
      LyricLine(
        id: 'demo-3',
        startTimeMs: 6850,
        endTimeMs: 9600,
        calls: [LineCallTag(presetId: 'updraft')],
        customShout: 'ハイ！ハイ！ハイハイハイ！',
        text: LyricText(
          original: '光の中へ 駆け出そうよ',
          ruby:
              '<ruby>光<rt>ひかり</rt></ruby>の<ruby>中<rt>なか</rt></ruby>へ <ruby>駆<rt>か</rt></ruby>け<ruby>出<rt>だ</rt></ruby>そうよ',
          romaji: 'Hikari no naka e kakedasou yo',
          translation: '向着光芒之中 一起奔跑吧',
        ),
      ),
      LyricLine(
        id: 'demo-4',
        startTimeMs: 9600,
        endTimeMs: 12340,
        calls: [LineCallTag(presetId: 'ppph', suffix: '×2')],
        customShout: 'オー！ハイ！オー！ハイ！',
        text: LyricText(
          original: '僕らの声で 未来を描こう',
          ruby:
              '<ruby>僕<rt>ぼく</rt></ruby>らの<ruby>声<rt>こえ</rt></ruby>で <ruby>未来<rt>みらい</rt></ruby>を<ruby>描<rt>えが</rt></ruby>こう',
          romaji: 'Bokura no koe de mirai wo egakou',
          translation: '用我们的声音 描绘出未来',
        ),
      ),
      LyricLine(
        id: 'demo-5',
        startTimeMs: 12340,
        endTimeMs: 15080,
        calls: [
          LineCallTag(presetId: 'ppph', suffix: '×2'),
          LineCallTag(presetId: 'ura-jump'),
        ],
        customShout: 'せーの！はいせーの！',
        text: LyricText(
          original: '手を伸ばしたら 届くはずさ',
          ruby:
              '<ruby>手<rt>て</rt></ruby>を<ruby>伸<rt>の</rt></ruby>ばしたら <ruby>届<rt>とど</rt></ruby>くはずさ',
          romaji: 'Te wo nobashitara todoku hazu sa',
          translation: '只要伸出双手 就一定能触及',
        ),
      ),
      LyricLine(
        id: 'demo-6',
        startTimeMs: 15080,
        endTimeMs: 17820,
        calls: [LineCallTag(presetId: 'flat-chop', suffix: '加速')],
        customShout: 'フッフー！ふわふわ！',
        text: LyricText(
          original: '輝くステージ 夢の向こうへ',
          ruby:
              '<ruby>輝<rt>かがや</rt></ruby>くステージ <ruby>夢<rt>ゆめ</rt></ruby>の<ruby>向<rt>む</rt></ruby>こうへ',
          romaji: 'Kagayaku suteeji yume no mukou e',
          translation: '闪耀的舞台 去往梦想的彼岸',
        ),
      ),
      LyricLine(
        id: 'demo-7',
        startTimeMs: 17820,
        endTimeMs: 20570,
        calls: [LineCallTag(presetId: 'front-wave', suffix: '全员')],
        customShout: 'オーーッ！オイ！オイ！',
        text: LyricText(
          original: '全力で叫べ 熱い想い',
          ruby:
              '<ruby>全力<rt>ぜんりょく</rt></ruby>で<ruby>叫<rt>さけ</rt></ruby>べ <ruby>熱<rt>あつ</rt></ruby>い<ruby>想<rt>おも</rt></ruby>い',
          romaji: 'Zenryoku de sakebe atsui omoi',
          translation: '全力呐喊吧 炽热的心意',
        ),
      ),
      LyricLine(
        id: 'demo-8',
        startTimeMs: 20570,
        endTimeMs: 24000,
        calls: [
          LineCallTag(presetId: 'wiper', suffix: '×4'),
          LineCallTag(presetId: 'front-wave'),
        ],
        customShout: 'ラストスパート！',
        text: LyricText(
          original: 'ひとつになる瞬間 忘れないで',
          ruby:
              'ひとつになる<ruby>瞬間<rt>しゅんかん</rt></ruby> <ruby>忘<rt>わす</rt></ruby>れないで',
          romaji: 'Hitotsu ni naru shunkan wasurenaide',
          translation: '融为一体的瞬间 请不要忘记',
        ),
      ),
      LyricLine(
        id: 'demo-outro-1',
        startTimeMs: 24000,
        endTimeMs: 48000,
        kind: LyricLineKind.outro,
        autoGenerated: true,
        calls: [LineCallTag(presetId: 'front-wave', suffix: '×4')],
        customShout: 'ハイ！ハイ！オーーッ！👏',
        text: LyricText(
          original: '【尾奏】',
          translation: '尾奏空档 24.0s（可标结尾 Call / 拍手 / 口上）',
        ),
      ),
    ],
  );
}

class DisplayLayers {
  const DisplayLayers({
    this.showRuby = true,
    this.showRomaji = false,
    this.showTranslation = true,
  });

  final bool showRuby;
  final bool showRomaji;
  final bool showTranslation;

  DisplayLayers copyWith({
    bool? showRuby,
    bool? showRomaji,
    bool? showTranslation,
  }) => DisplayLayers(
    showRuby: showRuby ?? this.showRuby,
    showRomaji: showRomaji ?? this.showRomaji,
    showTranslation: showTranslation ?? this.showTranslation,
  );

  Map<String, dynamic> toJson() => {
    'showRuby': showRuby,
    'showRomaji': showRomaji,
    'showTranslation': showTranslation,
  };

  factory DisplayLayers.fromJson(Map<String, dynamic> json) => DisplayLayers(
    showRuby: json['showRuby'] != false,
    showRomaji: json['showRomaji'] == true,
    showTranslation: json['showTranslation'] != false,
  );
}

class TrackSummary {
  const TrackSummary({
    required this.id,
    required this.platform,
    required this.title,
    required this.artist,
    this.album = '',
    this.durationMs = 0,
    this.bpm,
    this.hasSyncedLyrics = false,
    this.hasAudioUrl = false,
    required this.provider,
  });

  final String id;
  final String platform;
  final String title;
  final String artist;
  final String album;
  final int durationMs;
  final int? bpm;
  final bool hasSyncedLyrics;
  final bool hasAudioUrl;
  final String provider;

  factory TrackSummary.fromJson(Map<String, dynamic> json) => TrackSummary(
    id: json['id']?.toString() ?? '',
    platform: json['platform']?.toString() ?? 'synthetic',
    title: json['title']?.toString() ?? 'Unknown Track',
    artist: json['artist']?.toString() ?? '',
    album: json['album']?.toString() ?? '',
    durationMs: (json['durationMs'] as num?)?.round() ?? 0,
    bpm: (json['bpm'] as num?)?.round(),
    hasSyncedLyrics: json['hasSyncedLyrics'] == true,
    hasAudioUrl: json['hasAudioUrl'] == true,
    provider: json['provider']?.toString() ?? '',
  );
}

class SearchResponse {
  const SearchResponse({
    required this.query,
    required this.providerUsed,
    this.fallbackTriggered = false,
    this.results = const [],
  });

  final String query;
  final String providerUsed;
  final bool fallbackTriggered;
  final List<TrackSummary> results;

  factory SearchResponse.fromJson(Map<String, dynamic> json) {
    final items = json['results'] as List<dynamic>? ?? const [];
    return SearchResponse(
      query: json['query']?.toString() ?? '',
      providerUsed: json['providerUsed']?.toString() ?? '',
      fallbackTriggered: json['fallbackTriggered'] == true,
      results: [
        for (final item in items)
          if (item is Map<String, dynamic>) TrackSummary.fromJson(item),
      ],
    );
  }
}

class TrackDetailResponse {
  const TrackDetailResponse({
    required this.track,
    this.audioUrl = '',
    this.rawLrc = '',
    this.translatedLrc = '',
    this.lines = const [],
  });

  final TrackSummary track;
  final String audioUrl;
  final String rawLrc;
  final String translatedLrc;
  final List<LyricLine> lines;

  factory TrackDetailResponse.fromJson(Map<String, dynamic> json) {
    final rawLines = json['lines'] as List<dynamic>? ?? const [];
    return TrackDetailResponse(
      track: TrackSummary.fromJson(
        (json['track'] as Map<String, dynamic>?) ?? const {},
      ),
      audioUrl: json['audioUrl']?.toString() ?? '',
      rawLrc: json['rawLrc']?.toString() ?? '',
      translatedLrc: json['translatedLrc']?.toString() ?? '',
      lines: [
        for (final item in rawLines)
          if (item is Map<String, dynamic>) LyricLine.fromJson(item),
      ],
    );
  }
}

class CallbookArchiveEntry {
  const CallbookArchiveEntry({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.savedAt,
    required this.project,
    this.customPresets = const [],
    this.lineCount = 0,
    this.taggedCount = 0,
    this.alertCount = 0,
  });

  final String id;
  final String name;
  final int createdAt;
  final int savedAt;
  final CallProject project;
  final List<CallPreset> customPresets;
  final int lineCount;
  final int taggedCount;
  final int alertCount;

  static int computeTaggedCount(CallProject proj) => proj.lines
      .where(
        (l) =>
            l.calls.isNotEmpty ||
            l.customShout.trim().isNotEmpty ||
            l.tailUpdraft,
      )
      .length;

  CallbookArchiveEntry copyWith({
    String? id,
    String? name,
    int? createdAt,
    int? savedAt,
    CallProject? project,
    List<CallPreset>? customPresets,
    int? lineCount,
    int? taggedCount,
    int? alertCount,
  }) {
    final nextProj = project ?? this.project;
    return CallbookArchiveEntry(
      id: id ?? this.id,
      name: name ?? this.name,
      createdAt: createdAt ?? this.createdAt,
      savedAt: savedAt ?? this.savedAt,
      project: nextProj,
      customPresets: customPresets ?? this.customPresets,
      lineCount: lineCount ?? nextProj.lines.length,
      taggedCount: taggedCount ?? computeTaggedCount(nextProj),
      alertCount: alertCount ?? nextProj.alerts.length,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'createdAt': createdAt,
    'savedAt': savedAt,
    'project': project.toJson(),
    'customPresets': [for (final p in customPresets) p.toJson()],
    'lineCount': lineCount,
    'taggedCount': taggedCount,
    'alertCount': alertCount,
  };

  factory CallbookArchiveEntry.fromJson(Map<String, dynamic> json) {
    final proj = CallProject.fromJson(
      (json['project'] as Map<String, dynamic>?) ?? const {},
    );
    final rawPresets = json['customPresets'] as List<dynamic>? ?? const [];
    final now = DateTime.now().millisecondsSinceEpoch;
    return CallbookArchiveEntry(
      id: json['id']?.toString() ?? 'archive-$now',
      name: json['name']?.toString() ??
          (proj.meta.title.trim().isNotEmpty ? proj.meta.title : '未命名 Call 本'),
      createdAt: (json['createdAt'] as num?)?.toInt() ?? now,
      savedAt: (json['savedAt'] as num?)?.toInt() ?? now,
      project: proj,
      customPresets: [
        for (final p in rawPresets)
          if (p is Map<String, dynamic>) CallPreset.fromJson(p),
      ],
      lineCount: (json['lineCount'] as num?)?.toInt() ?? proj.lines.length,
      taggedCount:
          (json['taggedCount'] as num?)?.toInt() ?? computeTaggedCount(proj),
      alertCount: (json['alertCount'] as num?)?.toInt() ?? proj.alerts.length,
    );
  }
}

class ArchiveSessionState {
  const ArchiveSessionState({
    this.activeArchiveId,
    this.hasUnsavedChanges = false,
    this.hasFetchedExternalLyrics = false,
  });

  final String? activeArchiveId;
  final bool hasUnsavedChanges;
  final bool hasFetchedExternalLyrics;

  Map<String, dynamic> toJson() => {
    'activeArchiveId': activeArchiveId,
    'hasUnsavedChanges': hasUnsavedChanges,
    'hasFetchedExternalLyrics': hasFetchedExternalLyrics,
  };

  factory ArchiveSessionState.fromJson(Map<String, dynamic> json) =>
      ArchiveSessionState(
        activeArchiveId: json['activeArchiveId']?.toString(),
        hasUnsavedChanges: json['hasUnsavedChanges'] == true,
        hasFetchedExternalLyrics: json['hasFetchedExternalLyrics'] == true,
      );
}
