import 'dart:ui' show Color;

import '../models/callbook_models.dart';
import '../utils/section_detector.dart';

class OnboardingThemeColorOption {
  const OnboardingThemeColorOption({
    required this.name,
    required this.color,
    required this.hex,
    required this.subtitle,
  });

  final String name;
  final Color color;
  final String hex;
  final String subtitle;
}

const List<OnboardingThemeColorOption> defaultOnboardingThemeColors = [
  OnboardingThemeColorOption(
    name: '天依蓝',
    color: Color(0xFF66CCFF),
    hex: '#66CCFF',
    subtitle: '洛天依经典应援色',
  ),
  OnboardingThemeColorOption(
    name: '初音绿',
    color: Color(0xFF39C5BB),
    hex: '#39C5BB',
    subtitle: '初音未来苍绿应援色',
  ),
  OnboardingThemeColorOption(
    name: '香澄红',
    color: Color(0xFFFF5522),
    hex: '#FF5522',
    subtitle: 'BanG Dream! Poppin\'Party',
  ),
];

class DefaultSongSpec {
  const DefaultSongSpec({
    required this.id,
    required this.archiveId,
    required this.subtitle,
    required this.durationMs,
    required this.neteaseSearchQuery,
    required this.project,
  });

  final String id;
  final String archiveId;
  final String subtitle;
  final int durationMs;
  final String neteaseSearchQuery;
  final CallProject project;

  CallProject buildCleanProject() {
    final detected = detectAndMergeSections(
      project.lines,
      totalDurationMs: durationMs,
    );
    return CallProject(
      meta: project.meta,
      alerts: const [],
      lines: [
        for (final line in detected.lines)
          line.copyWith(
            calls: const [],
            customShout: '',
            tailUpdraft: false,
            alignedCalls: const [],
          ),
      ],
    );
  }
}

final List<DefaultSongSpec> defaultSongs = List.unmodifiable([
  _vanaheimSpec,
  _kizunaMusicSpec,
  _worldIsMineSpec,
]);

DefaultSongSpec get defaultPrimarySong => _vanaheimSpec;

DefaultSongSpec? findDefaultSongById(String? id) {
  if (id == null || id.isEmpty) return null;
  for (final song in defaultSongs) {
    if (song.id == id || song.archiveId == id) return song;
  }
  return null;
}

DefaultSongSpec? findDefaultSongByProject(CallProject project) {
  final title = project.meta.title.trim();
  for (final song in defaultSongs) {
    if (song.project.meta.title == title) {
      return song;
    }
  }
  return null;
}

/// Builds clean initial archive entries for all default songs.
///
/// The active primary song (`来自瓦纳海姆`) gets the newest `savedAt` timestamp
/// so it sorts first cleanly in Archive Quick Switcher.
List<CallbookArchiveEntry> buildDefaultArchiveEntries({int? nowMs}) {
  final base = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  return [
    for (var i = 0; i < defaultSongs.length; i++)
      (() {
        final spec = defaultSongs[i];
        final clean = spec.buildCleanProject();
        return CallbookArchiveEntry(
          id: spec.archiveId,
          name: clean.meta.title,
          createdAt: base - i * 1000,
          savedAt: base - i * 1000,
          project: clean,
          customPresets: const [],
          lineCount: clean.lines.length,
          taggedCount: 0,
          alertCount: 0,
        );
      })(),
  ];
}

final DefaultSongSpec _vanaheimSpec = const DefaultSongSpec(
  id: 'default-vanaheim',
  archiveId: 'default-archive-vanaheim',
  subtitle: '洛天依 · 148 BPM · 03:54',
  durationMs: 234000,
  neteaseSearchQuery: '来自瓦纳海姆 洛天依',
  project: CallProject(
    meta: CallProjectMeta(
      title: '来自瓦纳海姆',
      artist: '洛天依',
      platform: 'netease',
      trackId: null,
      audioUrl: '',
      bpm: 148,
      timeSignature: '4/4',
      offsetMs: 0,
      composer: 'litterzy',
      lyricist: '冥凰',
      vocalist: '洛天依',
      tuner: 'Creuzer',
      showTuner: true,
      editorName: '',
      editorNote: '',
    ),
    alerts: [],
    lines: [
      LyricLine(
        id: 'van-1',
        startTimeMs: 12000,
        endTimeMs: 19000,
        text: LyricText(original: '带我捕捉那道光芒 向更远远方'),
      ),
      LyricLine(
        id: 'van-2',
        startTimeMs: 19000,
        endTimeMs: 26000,
        text: LyricText(original: '这胸口跳动不已的心脏 一定有无穷的力量'),
      ),
      LyricLine(
        id: 'van-3',
        startTimeMs: 36000,
        endTimeMs: 43000,
        text: LyricText(original: '还来不及长大 眼底有太多期盼'),
      ),
      LyricLine(
        id: 'van-4',
        startTimeMs: 43000,
        endTimeMs: 50000,
        text: LyricText(original: '轻轻折一枚纸飞机 推向夜空的彼端'),
      ),
      LyricLine(
        id: 'van-5',
        startTimeMs: 50000,
        endTimeMs: 57000,
        text: LyricText(original: '无数星辰璀璨 也许隐藏着答案'),
      ),
      LyricLine(
        id: 'van-6',
        startTimeMs: 57000,
        endTimeMs: 64500,
        text: LyricText(original: '像命中注定的牵绊 你向我发出邀请函'),
      ),
      LyricLine(
        id: 'van-7',
        startTimeMs: 64500,
        endTimeMs: 72000,
        text: LyricText(original: '现在就决定出发吧 我的伙伴'),
      ),
      LyricLine(
        id: 'van-8',
        startTimeMs: 72000,
        endTimeMs: 79500,
        text: LyricText(original: '穿越银河这一次 不想再有遗憾'),
      ),
      LyricLine(
        id: 'van-9',
        startTimeMs: 79500,
        endTimeMs: 86500,
        text: LyricText(original: '带我飞去你的身旁 放声地歌唱'),
      ),
      LyricLine(
        id: 'van-10',
        startTimeMs: 86500,
        endTimeMs: 93500,
        text: LyricText(original: '哪怕旅途会失望会受伤 我还有梦想作翅膀'),
      ),
      LyricLine(
        id: 'van-11',
        startTimeMs: 93500,
        endTimeMs: 100500,
        text: LyricText(original: '带我捕捉那道光芒 向更远远方'),
      ),
      LyricLine(
        id: 'van-12',
        startTimeMs: 100500,
        endTimeMs: 108000,
        text: LyricText(original: '这胸口跳动不已的心脏 一定有无穷的力量'),
      ),
      LyricLine(
        id: 'van-13',
        startTimeMs: 124000,
        endTimeMs: 131000,
        text: LyricText(original: '不断相遇告别 一个又一个光环'),
      ),
      LyricLine(
        id: 'van-14',
        startTimeMs: 131000,
        endTimeMs: 138000,
        text: LyricText(original: '拼命忍耐这孤独感 只为把距离缩短'),
      ),
      LyricLine(
        id: 'van-15',
        startTimeMs: 138000,
        endTimeMs: 145000,
        text: LyricText(original: '浩瀚的宇宙中 没有谁会不勇敢'),
      ),
      LyricLine(
        id: 'van-16',
        startTimeMs: 145000,
        endTimeMs: 152000,
        text: LyricText(original: '再渺小轨迹也能够 织出最美好的片段'),
      ),
      LyricLine(
        id: 'van-17',
        startTimeMs: 152000,
        endTimeMs: 159000,
        text: LyricText(original: '尽管对未来还有些 憧憬不安'),
      ),
      LyricLine(
        id: 'van-18',
        startTimeMs: 159000,
        endTimeMs: 166000,
        text: LyricText(original: '也要全力用歌声 将全世界填满'),
      ),
      LyricLine(
        id: 'van-19',
        startTimeMs: 166000,
        endTimeMs: 172500,
        text: LyricText(original: '带我飞去你的身旁 放声地歌唱'),
      ),
      LyricLine(
        id: 'van-20',
        startTimeMs: 172500,
        endTimeMs: 179500,
        text: LyricText(original: '哪怕将褪去稚嫩的模样 也不会迷失我方向'),
      ),
      LyricLine(
        id: 'van-21',
        startTimeMs: 179500,
        endTimeMs: 186000,
        text: LyricText(original: '带我捕捉那道光芒 向更远远方'),
      ),
      LyricLine(
        id: 'van-22',
        startTimeMs: 186000,
        endTimeMs: 193000,
        text: LyricText(original: '直到我抵达舞台的中央 用梦想去传递梦想'),
      ),
      LyricLine(
        id: 'van-23',
        startTimeMs: 193000,
        endTimeMs: 199000,
        text: LyricText(original: '带我飞去你的身旁 放声地歌唱'),
      ),
      LyricLine(
        id: 'van-24',
        startTimeMs: 199000,
        endTimeMs: 205500,
        text: LyricText(original: '哪怕旅途会失望会受伤 我还有梦想作翅膀'),
      ),
      LyricLine(
        id: 'van-25',
        startTimeMs: 205500,
        endTimeMs: 211500,
        text: LyricText(original: '带我捕捉那道光芒 向更远远方'),
      ),
      LyricLine(
        id: 'van-26',
        startTimeMs: 211500,
        endTimeMs: 218000,
        text: LyricText(original: '这胸口跳动不已的心脏 一定有无穷的力量'),
      ),
    ],
  ),
);

final DefaultSongSpec _kizunaMusicSpec = const DefaultSongSpec(
  id: 'default-kizuna-music',
  archiveId: 'default-archive-kizuna-music',
  subtitle: "Poppin'Party · 189 BPM · 05:17",
  durationMs: 317000,
  neteaseSearchQuery: "キズナミュージック Poppin'Party",
  project: CallProject(
    meta: CallProjectMeta(
      title: 'キズナミュージック♪（友谊的华章）',
      artist: "Poppin'Party",
      platform: 'netease',
      trackId: null,
      audioUrl: '',
      bpm: 189,
      timeSignature: '4/4',
      offsetMs: 0,
      composer: '藤永龍太郎(Elements Garden)',
      lyricist: '中村航',
      vocalist: "Poppin'Party",
      tuner: '',
      showTuner: false,
      editorName: '',
      editorNote: '',
    ),
    alerts: [],
    lines: [
      LyricLine(
        id: 'kiz-1',
        startTimeMs: 10410,
        endTimeMs: 15540,
        text: LyricText(
          original: '教室の窓の外 はしゃぐ声',
          ruby:
              '<ruby>教室<rt>きょうしつ</rt></ruby>の<ruby>窓<rt>まど</rt></ruby>の<ruby>外<rt>そと</rt></ruby> はしゃぐ<ruby>声<rt>こえ</rt></ruby>',
          romaji: 'Kyoushitsu no mado no soto hashagu koe',
          translation: '教室窗外传来的嬉闹声',
        ),
      ),
      LyricLine(
        id: 'kiz-2',
        startTimeMs: 15540,
        endTimeMs: 20590,
        text: LyricText(
          original: '木漏れ日は キラキラ降り注いで',
          ruby:
              '<ruby>木漏<rt>こも</rt></ruby>れ<ruby>日<rt>び</rt></ruby>は キラキラ<ruby>降<rt>ふ</rt></ruby>り<ruby>注<rt>そそ</rt></ruby>いで',
          romaji: 'Komorebi wa kirakira furisosoide',
          translation: '斑驳树影间 洒下闪闪阳光',
        ),
      ),
      LyricLine(
        id: 'kiz-3',
        startTimeMs: 20590,
        endTimeMs: 25710,
        text: LyricText(
          original: '毎日が特別だった場所に',
          ruby:
              '<ruby>毎日<rt>まいにち</rt></ruby>が<ruby>特別<rt>とくべつ</rt></ruby>だった<ruby>場所<rt>ばしょ</rt></ruby>に',
          romaji: 'Mainichi ga tokubetsu datta basho ni',
          translation: '在曾让每一天都如此特别的地方',
        ),
      ),
      LyricLine(
        id: 'kiz-4',
        startTimeMs: 25710,
        endTimeMs: 29510,
        text: LyricText(
          original: 'みんな また集まってた',
          ruby: 'みんな また<ruby>集<rt>あつ</rt></ruby>まってた',
          romaji: 'Minna mata atsumatteta',
          translation: '大家又一次相聚于此',
        ),
      ),
      LyricLine(
        id: 'kiz-5',
        startTimeMs: 29510,
        endTimeMs: 35900,
        text: LyricText(
          original: 'わたしたちが つながってる意味',
          ruby: 'わたしたちが つながってる<ruby>意味<rt>いみ</rt></ruby>',
          romaji: 'Watashitachi ga tsunagatteru imi',
          translation: '我们紧紧相连的意义',
        ),
      ),
      LyricLine(
        id: 'kiz-6',
        startTimeMs: 35900,
        endTimeMs: 39640,
        text: LyricText(
          original: 'たぶん…偶然じゃない',
          ruby: 'たぶん…<ruby>偶然<rt>ぐうぜん</rt></ruby>じゃない',
          romaji: 'Tabun... guuzen ja nai',
          translation: '大概…并非偶然',
        ),
      ),
      LyricLine(
        id: 'kiz-7',
        startTimeMs: 39640,
        endTimeMs: 45430,
        text: LyricText(
          original: 'だって音を合わせたら',
          ruby: 'だって<ruby>音<rt>おと</rt></ruby>を<ruby>合<rt>あ</rt></ruby>わせたら',
          romaji: 'Datte oto wo awasetara',
          translation: '因为只要一同奏响旋律——',
        ),
      ),
      LyricLine(
        id: 'kiz-8',
        startTimeMs: 45430,
        endTimeMs: 48260,
        text: LyricText(
          original: 'キズナミュージック',
          ruby: 'キズナミュージック',
          romaji: 'Kizuna Myuujikku',
          translation: '羁绊的乐章（Kizuna Music）',
        ),
      ),
      LyricLine(
        id: 'kiz-9',
        startTimeMs: 48260,
        endTimeMs: 53360,
        text: LyricText(
          original: 'ただひたむきに 追いかけていた',
          ruby: 'ただひたむきに <ruby>追<rt>お</rt></ruby>いかけていた',
          romaji: 'Tada hitamuki ni oikaketeita',
          translation: '只是全心全意地 拼命追逐着',
        ),
      ),
      LyricLine(
        id: 'kiz-10',
        startTimeMs: 53360,
        endTimeMs: 58140,
        text: LyricText(
          original: '胸の奥の思い 気づいたら',
          ruby:
              '<ruby>胸<rt>むね</rt></ruby>の<ruby>奥<rt>おく</rt></ruby>の<ruby>思<rt>おも</rt></ruby>い <ruby>気<rt>き</rt></ruby>づいたら',
          romaji: 'Mune no oku no omoi kizuitara',
          translation: '只要发觉心底深处的那份心意',
        ),
      ),
      LyricLine(
        id: 'kiz-11',
        startTimeMs: 58140,
        endTimeMs: 61290,
        text: LyricText(
          original: '（みんなで）地図を広げて',
          ruby:
              '（みんなで）<ruby>地図<rt>ちず</rt></ruby>を<ruby>広<rt>ひろ</rt></ruby>げて',
          romaji: '(Minna de) chizu wo hirogete',
          translation: '（大家一起）展开地图',
        ),
      ),
      LyricLine(
        id: 'kiz-12',
        startTimeMs: 61290,
        endTimeMs: 65700,
        text: LyricText(
          original: 'キボウの道を ジグザグ進もう！',
          ruby:
              'キボウの<ruby>道<rt>みち</rt></ruby>を ジグザグ<ruby>進<rt>すす</rt></ruby>もう！',
          romaji: 'Kibou no michi wo jiguzagu susumou!',
          translation: '在希望之路上 曲折前行吧！',
        ),
      ),
      LyricLine(
        id: 'kiz-13',
        startTimeMs: 65700,
        endTimeMs: 68560,
        text: LyricText(
          original: 'キズナミュージック',
          ruby: 'キズナミュージック',
          romaji: 'Kizuna Myuujikku',
          translation: '羁绊的乐章（Kizuna Music）',
        ),
      ),
      LyricLine(
        id: 'kiz-14',
        startTimeMs: 68560,
        endTimeMs: 76220,
        text: LyricText(
          original: '大好きな歌 約束の歌 永遠の歌',
          ruby:
              '<ruby>大好<rt>だいす</rt></ruby>きな<ruby>歌<rt>うた</rt></ruby> <ruby>約束<rt>やくそく</rt></ruby>の<ruby>歌<rt>うた</rt></ruby> <ruby>永遠<rt>えいえん</rt></ruby>の<ruby>歌<rt>うた</rt></ruby>',
          romaji: 'Daisuki na uta yakusoku no uta eien no uta',
          translation: '最喜欢的歌 约定之歌 永恒之歌',
        ),
      ),
      LyricLine(
        id: 'kiz-15',
        startTimeMs: 76220,
        endTimeMs: 80920,
        text: LyricText(
          original: '届けよう！わたしたちいつだって',
          ruby: '<ruby>届<rt>とど</rt></ruby>けよう！わたしたちいつだって',
          romaji: 'Todokeyou! Watashitachi itsudatte',
          translation: '传达出去吧！我们无论何时',
        ),
      ),
      LyricLine(
        id: 'kiz-16',
        startTimeMs: 80920,
        endTimeMs: 85400,
        text: LyricText(
          original: '精一杯！Forever for dreaming!',
          ruby: '<ruby>精一杯<rt>せいいっぱい</rt></ruby>！Forever for dreaming!',
          romaji: 'Seiippai! Forever for dreaming!',
          translation: '都倾尽全力！Forever for dreaming!',
        ),
      ),
      LyricLine(
        id: 'kiz-17',
        startTimeMs: 85400,
        endTimeMs: 89910,
        text: LyricText(
          original: '夢の向こうへ',
          ruby: '<ruby>夢<rt>ゆめ</rt></ruby>の<ruby>向<rt>む</rt></ruby>こうへ',
          romaji: 'Yume no mukou e',
          translation: '迈向梦想的彼方',
        ),
      ),
      LyricLine(
        id: 'kiz-18',
        startTimeMs: 96750,
        endTimeMs: 101910,
        text: LyricText(
          original: '出会ったときのこと 覚えている？',
          ruby:
              '<ruby>出会<rt>であ</rt></ruby>ったときのこと <ruby>覚<rt>おぼ</rt></ruby>えている？',
          romaji: 'Deatta toki no koto oboeteiru?',
          translation: '初遇那天的光景 你还记得吗？',
        ),
      ),
      LyricLine(
        id: 'kiz-19',
        startTimeMs: 101910,
        endTimeMs: 106960,
        text: LyricText(
          original: 'あふれだす思い 響きあう夢',
          ruby:
              'あふれだす<ruby>思<rt>おも</rt></ruby>い <ruby>響<rt>ひび</rt></ruby>きあう<ruby>夢<rt>ゆめ</rt></ruby>',
          romaji: 'Afuredasu omoi hibikiau yume',
          translation: '满溢而出的思绪 相互共鸣的梦想',
        ),
      ),
      LyricLine(
        id: 'kiz-20',
        startTimeMs: 106960,
        endTimeMs: 112080,
        text: LyricText(
          original: '気づいたら 傷ついて傷つけて',
          ruby:
              '<ruby>気<rt>き</rt></ruby>づいたら <ruby>傷<rt>きず</rt></ruby>ついて<ruby>傷<rt>きず</rt></ruby>つけて',
          romaji: 'Kizuitara kizutsuite kizutsukete',
          translation: '回过神来 曾受过伤也曾刺伤彼此',
        ),
      ),
      LyricLine(
        id: 'kiz-21',
        startTimeMs: 112080,
        endTimeMs: 115920,
        text: LyricText(
          original: '絆 また深まってた',
          ruby: '<ruby>絆<rt>きずな</rt></ruby> また<ruby>深<rt>ふか</rt></ruby>まってた',
          romaji: 'Kizuna mata fukamatteta',
          translation: '可羁绊却又一次变得更深',
        ),
      ),
      LyricLine(
        id: 'kiz-22',
        startTimeMs: 115920,
        endTimeMs: 122300,
        text: LyricText(
          original: '五人だけが 知っていること',
          ruby: '<ruby>五人<rt>ごにん</rt></ruby>だけが <ruby>知<rt>し</rt></ruby>っていること',
          romaji: 'Gonin dake ga shitteiru koto',
          translation: '只有我们五人知道的事',
        ),
      ),
      LyricLine(
        id: 'kiz-23',
        startTimeMs: 122300,
        endTimeMs: 126070,
        text: LyricText(
          original: 'たぶん…すぐ思いだす',
          ruby: 'たぶん…すぐ<ruby>思<rt>おも</rt></ruby>いだす',
          romaji: 'Tabun... sugu omoidasu',
          translation: '大概…马上就能回想起来',
        ),
      ),
      LyricLine(
        id: 'kiz-24',
        startTimeMs: 126070,
        endTimeMs: 131790,
        text: LyricText(
          original: '歌が教えてくれるよ',
          ruby: '<ruby>歌<rt>うた</rt></ruby>が<ruby>教<rt>おし</rt></ruby>えてくれるよ',
          romaji: 'Uta ga oshiete kureru yo',
          translation: '歌声会告诉我们的哦',
        ),
      ),
      LyricLine(
        id: 'kiz-25',
        startTimeMs: 131790,
        endTimeMs: 134720,
        text: LyricText(
          original: 'キズナミュージック',
          ruby: 'キズナミュージック',
          romaji: 'Kizuna Myuujikku',
          translation: '羁绊的乐章（Kizuna Music）',
        ),
      ),
      LyricLine(
        id: 'kiz-26',
        startTimeMs: 134720,
        endTimeMs: 139580,
        text: LyricText(
          original: 'あの橋渡り あの丘を越え',
          ruby:
              'あの<ruby>橋<rt>はし</rt></ruby><ruby>渡<rt>わた</rt></ruby>り あの<ruby>丘<rt>おか</rt></ruby>を<ruby>越<rt>こ</rt></ruby>え',
          romaji: 'Ano hashi watari ano oka wo koe',
          translation: '跨过那座桥梁 翻过那座山丘',
        ),
      ),
      LyricLine(
        id: 'kiz-27',
        startTimeMs: 139580,
        endTimeMs: 144440,
        text: LyricText(
          original: 'その壁を越えたら キミがいた',
          ruby:
              'その<ruby>壁<rt>かべ</rt></ruby>を<ruby>越<rt>こ</rt></ruby>えたら キミがいた',
          romaji: 'Sono kabe wo koetara kimi ga ita',
          translation: '跨越那道高墙后 就能见到你',
        ),
      ),
      LyricLine(
        id: 'kiz-28',
        startTimeMs: 144440,
        endTimeMs: 147700,
        text: LyricText(
          original: '（会えたね）標識のない',
          ruby:
              '（<ruby>会<rt>あ</rt></ruby>えたね）<ruby>標識<rt>ひょうしき</rt></ruby>のない',
          romaji: '(Aeta ne) hyoushiki no nai',
          translation: '（终于相遇了呢）就算没有路标',
        ),
      ),
      LyricLine(
        id: 'kiz-29',
        startTimeMs: 147700,
        endTimeMs: 152100,
        text: LyricText(
          original: '迷いの道も キミとなら行ける',
          ruby:
              '<ruby>迷<rt>まよ</rt></ruby>いの<ruby>道<rt>みち</rt></ruby>も キミとなら<ruby>行<rt>い</rt></ruby>ける',
          romaji: 'Mayoi no michi mo kimi to nara ikeru',
          translation: '迷茫的道路 只要和你一起就能走下去',
        ),
      ),
      LyricLine(
        id: 'kiz-30',
        startTimeMs: 152100,
        endTimeMs: 154980,
        text: LyricText(
          original: 'キズナミュージック',
          ruby: 'キズナミュージック',
          romaji: 'Kizuna Myuujikku',
          translation: '羁绊的乐章（Kizuna Music）',
        ),
      ),
      LyricLine(
        id: 'kiz-31',
        startTimeMs: 154980,
        endTimeMs: 162560,
        text: LyricText(
          original: '大切な歌 青春の歌 始まりの歌',
          ruby:
              '<ruby>大切<rt>たいせつ</rt></ruby>な<ruby>歌<rt>うた</rt></ruby> <ruby>青春<rt>せいしゅん</rt></ruby>の<ruby>歌<rt>うた</rt></ruby> <ruby>始<rt>はじ</rt></ruby>まりの<ruby>歌<rt>うた</rt></ruby>',
          romaji: 'Taisetsu na uta seishun no uta hajimari no uta',
          translation: '珍贵之歌 青春之歌 起点之歌',
        ),
      ),
      LyricLine(
        id: 'kiz-32',
        startTimeMs: 162560,
        endTimeMs: 167300,
        text: LyricText(
          original: '奏でよう！何度でもいつまでも',
          ruby:
              '<ruby>奏<rt>かな</rt></ruby>でよう！<ruby>何度<rt>なんど</rt></ruby>でもいつまでも',
          romaji: 'Kanadeyou! Nando demo itsumademo',
          translation: '弹奏起来吧！无论多少次、无论到何时',
        ),
      ),
      LyricLine(
        id: 'kiz-33',
        startTimeMs: 167300,
        endTimeMs: 171810,
        text: LyricText(
          original: '精一杯！Forever for dreaming!',
          ruby: '<ruby>精一杯<rt>せいいっぱい</rt></ruby>！Forever for dreaming!',
          romaji: 'Seiippai! Forever for dreaming!',
          translation: '都要全力以赴！Forever for dreaming!',
        ),
      ),
      LyricLine(
        id: 'kiz-34',
        startTimeMs: 171810,
        endTimeMs: 176130,
        text: LyricText(
          original: '歌を信じる',
          ruby: '<ruby>歌<rt>うた</rt></ruby>を<ruby>信<rt>しん</rt></ruby>じる',
          romaji: 'Uta wo shinjiru',
          translation: '相信歌声的力量',
        ),
      ),
      LyricLine(
        id: 'kiz-35',
        startTimeMs: 216450,
        endTimeMs: 223850,
        text: LyricText(
          original: 'いつか 思い出に変わったとき',
          ruby:
              'いつか <ruby>思<rt>おも</rt></ruby>い<ruby>出<rt>で</rt></ruby>に<ruby>変<rt>か</rt></ruby>わったとき',
          romaji: 'Itsuka omoide ni kawatta toki',
          translation: '总有一天 当这一切化为回忆之时',
        ),
      ),
      LyricLine(
        id: 'kiz-36',
        startTimeMs: 223850,
        endTimeMs: 226740,
        text: LyricText(
          original: 'この歌を聴いたなら',
          ruby: 'この<ruby>歌<rt>うた</rt></ruby>を<ruby>聴<rt>き</rt></ruby>いたなら',
          romaji: 'Kono uta wo kiita nara',
          translation: '如果再次听见这首歌',
        ),
      ),
      LyricLine(
        id: 'kiz-37',
        startTimeMs: 226740,
        endTimeMs: 231110,
        text: LyricText(
          original: 'どんなことを感じるかな？',
          ruby: 'どんなことを<ruby>感<rt>かん</rt></ruby>じるかな？',
          romaji: 'Donna koto wo kanjiru ka na?',
          translation: '心头会涌上怎样的感受呢？',
        ),
      ),
      LyricLine(
        id: 'kiz-38',
        startTimeMs: 231110,
        endTimeMs: 237810,
        text: LyricText(
          original: '愛しくて 優しく 嬉しくて 切なかった',
          ruby:
              '<ruby>愛<rt>いと</rt></ruby>しくて <ruby>優<rt>やさ</rt></ruby>しく <ruby>嬉<rt>うれ</rt></ruby>しくて <ruby>切<rt>せつ</rt></ruby>なかった',
          romaji: 'Itoshikute yasashiku ureshikute setsunakatta',
          translation: '既珍爱 又温柔 既欢喜 又带着些许酸楚',
        ),
      ),
      LyricLine(
        id: 'kiz-39',
        startTimeMs: 237810,
        endTimeMs: 244730,
        text: LyricText(
          original: '思いすべて 抱きしめ',
          ruby: '<ruby>思<rt>おも</rt></ruby>いすべて <ruby>抱<rt>だ</rt></ruby>きしめ',
          romaji: 'Omoi subete dakishime',
          translation: '将这份全部的情感 紧紧拥入怀中',
        ),
      ),
      LyricLine(
        id: 'kiz-40',
        startTimeMs: 244730,
        endTimeMs: 247560,
        text: LyricText(
          original: 'キズナミュージック',
          ruby: 'キズナミュージック',
          romaji: 'Kizuna Myuujikku',
          translation: '羁绊的乐章（Kizuna Music）',
        ),
      ),
      LyricLine(
        id: 'kiz-41',
        startTimeMs: 247560,
        endTimeMs: 252400,
        text: LyricText(
          original: '心震えて 勇気あふれて 涙がでちゃいそう',
          ruby:
              '<ruby>心<rt>こころ</rt></ruby><ruby>震<rt>ふる</rt></ruby>えて <ruby>勇気<rt>ゆうき</rt></ruby>あふれて <ruby>涙<rt>なみだ</rt></ruby>がでちゃいそう',
          romaji: 'Kokoro furuete yuuki afurete namida ga dechaisou',
          translation: '心潮澎湃 勇气满溢 几乎都要落下泪来',
        ),
      ),
      LyricLine(
        id: 'kiz-42',
        startTimeMs: 252400,
        endTimeMs: 257440,
        text: LyricText(
          original: '歌おうよ',
          ruby: '<ruby>歌<rt>うた</rt></ruby>おうよ',
          romaji: 'Utaou yo',
          translation: '放声歌唱吧',
        ),
      ),
      LyricLine(
        id: 'kiz-43',
        startTimeMs: 257440,
        endTimeMs: 260690,
        text: LyricText(
          original: '（みんなで）声高らかに',
          ruby: '（みんなで）<ruby>声<rt>こえ</rt></ruby><ruby>高<rt>たか</rt></ruby>らかに',
          romaji: '(Minna de) koe takaraka ni',
          translation: '（大家一起）高声齐唱',
        ),
      ),
      LyricLine(
        id: 'kiz-44',
        startTimeMs: 260690,
        endTimeMs: 265010,
        text: LyricText(
          original: '明日の歌を 未来への歌を！',
          ruby:
              '<ruby>明日<rt>あした</rt></ruby>の<ruby>歌<rt>うた</rt></ruby>を <ruby>未来<rt>みらい</rt></ruby>への<ruby>歌<rt>うた</rt></ruby>を！',
          romaji: 'Ashita no uta wo mirai e no uta wo!',
          translation: '唱响明日之歌 唱响面向未来之歌！',
        ),
      ),
      LyricLine(
        id: 'kiz-45',
        startTimeMs: 265010,
        endTimeMs: 268610,
        text: LyricText(
          original: 'そんな…',
          ruby: 'そんな…',
          romaji: 'Sonna...',
          translation: '就是这样…',
        ),
      ),
      LyricLine(
        id: 'kiz-46',
        startTimeMs: 268610,
        endTimeMs: 270550,
        text: LyricText(
          original: 'ミュージック',
          ruby: 'ミュージック',
          romaji: 'Myuujikku',
          translation: '乐章（Music）',
        ),
      ),
      LyricLine(
        id: 'kiz-47',
        startTimeMs: 270550,
        endTimeMs: 278060,
        text: LyricText(
          original: '大好きな歌 約束の歌 永遠の歌',
          ruby:
              '<ruby>大好<rt>だいす</rt></ruby>きな<ruby>歌<rt>うた</rt></ruby> <ruby>約束<rt>やくそく</rt></ruby>の<ruby>歌<rt>うた</rt></ruby> <ruby>永遠<rt>えいえん</rt></ruby>の<ruby>歌<rt>うた</rt></ruby>',
          romaji: 'Daisuki na uta yakusoku no uta eien no uta',
          translation: '最喜欢的歌 约定之歌 永恒之歌',
        ),
      ),
      LyricLine(
        id: 'kiz-48',
        startTimeMs: 278060,
        endTimeMs: 282850,
        text: LyricText(
          original: '届けよう！わたしたちいつだって',
          ruby: '<ruby>届<rt>とど</rt></ruby>けよう！わたしたちいつだって',
          romaji: 'Todokeyou! Watashitachi itsudatte',
          translation: '传达出去吧！我们无论何时',
        ),
      ),
      LyricLine(
        id: 'kiz-49',
        startTimeMs: 282850,
        endTimeMs: 286610,
        text: LyricText(
          original: '精一杯！Forever for dreaming!',
          ruby: '<ruby>精一杯<rt>せいいっぱい</rt></ruby>！Forever for dreaming!',
          romaji: 'Seiippai! Forever for dreaming!',
          translation: '都倾尽全力！Forever for dreaming!',
        ),
      ),
      LyricLine(
        id: 'kiz-50',
        startTimeMs: 286610,
        endTimeMs: 289180,
        text: LyricText(
          original: 'キミと一緒だよ',
          ruby: 'キミと<ruby>一緒<rt>いっしょ</rt></ruby>だよ',
          romaji: 'Kimi to issho da yo',
          translation: '一直和你在一起哦',
        ),
      ),
      LyricLine(
        id: 'kiz-51',
        startTimeMs: 289180,
        endTimeMs: 292400,
        text: LyricText(
          original: 'Forever for dreaming!',
          ruby: 'Forever for dreaming!',
          romaji: 'Forever for dreaming!',
          translation: 'Forever for dreaming!',
        ),
      ),
      LyricLine(
        id: 'kiz-52',
        startTimeMs: 292400,
        endTimeMs: 296750,
        text: LyricText(
          original: 'キミを信じる',
          ruby: 'キミを<ruby>信<rt>しん</rt></ruby>じる',
          romaji: 'Kimi wo shinjiru',
          translation: '一直相信着你',
        ),
      ),
    ],
  ),
);

final DefaultSongSpec _worldIsMineSpec = const DefaultSongSpec(
  id: 'default-world-is-mine',
  archiveId: 'default-archive-world-is-mine',
  subtitle: 'supercell feat. 初音ミク · 165 BPM · 04:15',
  durationMs: 255000,
  neteaseSearchQuery: 'ワールドイズマイン 初音ミク',
  project: CallProject(
    meta: CallProjectMeta(
      title: 'ワールドイズマイン（世界第一的公主殿下）',
      artist: 'supercell feat. 初音ミク',
      platform: 'netease',
      trackId: null,
      audioUrl: '',
      bpm: 165,
      timeSignature: '4/4',
      offsetMs: 0,
      composer: 'ryo (supercell)',
      lyricist: 'ryo (supercell)',
      vocalist: '初音ミク',
      tuner: '',
      showTuner: false,
      editorName: '',
      editorNote: '',
    ),
    alerts: [],
    lines: [
      LyricLine(
        id: 'wim-1',
        startTimeMs: 1040,
        endTimeMs: 6780,
        text: LyricText(
          original: '世界で一番 おひめさま',
          ruby:
              '<ruby>世界<rt>せかい</rt></ruby>で<ruby>一番<rt>いちばん</rt></ruby> おひめさま',
          romaji: 'Sekai de ichiban ohimesama',
          translation: '世界第一的公主殿下',
        ),
      ),
      LyricLine(
        id: 'wim-2',
        startTimeMs: 6780,
        endTimeMs: 10800,
        text: LyricText(
          original: 'そういう扱い 心得てよね',
          ruby:
              'そういう<ruby>扱<rt>あつか</rt></ruby>い <ruby>心得<rt>こころえ</rt></ruby>てよね',
          romaji: 'Souiu atsukai kokoroete yo ne',
          translation: '请记住要这样对待我哦',
        ),
      ),
      LyricLine(
        id: 'wim-3',
        startTimeMs: 29120,
        endTimeMs: 34660,
        text: LyricText(
          original: 'その一 いつもと違う髪形に気がつくこと',
          ruby:
              'その<ruby>一<rt>いち</rt></ruby> いつもと<ruby>違<rt>ちが</rt></ruby>う<ruby>髪形<rt>かみがた</rt></ruby>に<ruby>気<rt>き</rt></ruby>がつくこと',
          romaji: 'Sono ichi itsumo to chigau kamigata ni ki ga tsuku koto',
          translation: '第一点 要注意到我和平时不同的发型',
        ),
      ),
      LyricLine(
        id: 'wim-4',
        startTimeMs: 34660,
        endTimeMs: 40040,
        text: LyricText(
          original: 'その二 ちゃんと靴まで見ること いいね？',
          ruby:
              'その<ruby>二<rt>に</rt></ruby> ちゃんと<ruby>靴<rt>くつ</rt></ruby>まで<ruby>見<rt>み</rt></ruby>ること いいね？',
          romaji: 'Sono ni chanto kutsu made miru koto ii ne?',
          translation: '第二点 连同鞋子也要好好夸赞 明白了吗？',
        ),
      ),
      LyricLine(
        id: 'wim-5',
        startTimeMs: 40040,
        endTimeMs: 45410,
        text: LyricText(
          original: 'その三 わたしの一言には 三つの言葉で返事すること',
          ruby:
              'その<ruby>三<rt>さん</rt></ruby> わたしの<ruby>一言<rt>ひとこと</rt></ruby>には <ruby>三<rt>みっ</rt></ruby>つの<ruby>言葉<rt>ことば</rt></ruby>で<ruby>返事<rt>へんじ</rt></ruby>すること',
          romaji: 'Sono san watashi no hitokoto ni wa mittsu no kotoba de henji suru koto',
          translation: '第三点 我说一句话你要用三句话来回答',
        ),
      ),
      LyricLine(
        id: 'wim-6',
        startTimeMs: 45410,
        endTimeMs: 50940,
        text: LyricText(
          original: 'わかったら 右手がお留守なのを なんとかして！',
          ruby:
              'わかったら <ruby>右手<rt>みぎて</rt></ruby>がお<ruby>留守<rt>るす</rt></ruby>なのを なんとかして！',
          romaji: 'Wakattara migite ga orusu na no wo nantoka shite!',
          translation: '明白了的话 就快点过来牵起我空着的右手吧！',
        ),
      ),
      LyricLine(
        id: 'wim-7',
        startTimeMs: 50940,
        endTimeMs: 53920,
        text: LyricText(
          original: 'べつに わがままなんて言ってないんだから',
          ruby:
              'べつに わがままなんて<ruby>言<rt>い</rt></ruby>ってないんだから',
          romaji: 'Betsu ni wagamama nante ittenain da kara',
          translation: '人家才没有在耍任性呢',
        ),
      ),
      LyricLine(
        id: 'wim-8',
        startTimeMs: 53920,
        endTimeMs: 56390,
        text: LyricText(
          original: 'キミに心から思って欲しいの かわいいって',
          ruby:
              'キミに<ruby>心<rt>こころ</rt></ruby>から<ruby>思<rt>おも</rt></ruby>って<ruby>欲<rt>ほ</rt></ruby>しいの かわいいって',
          romaji: 'Kimi ni kokoro kara omotte hoshii no kawaii tte',
          translation: '我只是想让你由衷地觉得「真是太可爱了」',
        ),
      ),
      LyricLine(
        id: 'wim-9',
        startTimeMs: 56390,
        endTimeMs: 58590,
        text: LyricText(
          original: '世界で一番 おひめさま',
          ruby:
              '<ruby>世界<rt>せかい</rt></ruby>で<ruby>一番<rt>いちばん</rt></ruby> おひめさま',
          romaji: 'Sekai de ichiban ohimesama',
          translation: '世界第一的公主殿下',
        ),
      ),
      LyricLine(
        id: 'wim-10',
        startTimeMs: 58590,
        endTimeMs: 63470,
        text: LyricText(
          original: '気がついて ねぇねぇ 待たせるなんて論外よ',
          ruby:
              '<ruby>気<rt>き</rt></ruby>がついて ねぇねぇ <ruby>待<rt>ま</rt></ruby>たせるなんて<ruby>論外<rt>ろんがい</rt></ruby>よ',
          romaji: 'Ki ga tsuite nee nee mataseru nante rongai yo',
          translation: '快注意到啊 呐呐 让我等什么的简直太不像话',
        ),
      ),
      LyricLine(
        id: 'wim-11',
        startTimeMs: 63470,
        endTimeMs: 67890,
        text: LyricText(
          original: 'わたしを誰だと思ってるの？',
          ruby:
              'わたしを<ruby>誰<rt>だれ</rt></ruby>だと<ruby>思<rt>おも</rt></ruby>ってるの？',
          romaji: 'Watashi wo dare da to omotteru no?',
          translation: '你以为我是谁呀？',
        ),
      ),
      LyricLine(
        id: 'wim-12',
        startTimeMs: 67890,
        endTimeMs: 72050,
        text: LyricText(
          original: 'もうなんだかい 甘いものが食べたい！',
          ruby:
              'もうなんだかい <ruby>甘<rt>あま</rt></ruby>いものが<ruby>食<rt>た</rt></ruby>べたい！',
          romaji: 'Mou nandakai amai mono ga tabetai!',
          translation: '真是的 突然好想吃甜点！',
        ),
      ),
      LyricLine(
        id: 'wim-13',
        startTimeMs: 72050,
        endTimeMs: 76290,
        text: LyricText(
          original: 'いますぐによ',
          ruby: 'いますぐによ',
          romaji: 'Ima sugu ni yo',
          translation: '现在马上就要！',
        ),
      ),
      LyricLine(
        id: 'wim-14',
        startTimeMs: 76290,
        endTimeMs: 80500,
        text: LyricText(
          original: '手をとって 連れてって',
          ruby: '<ruby>手<rt>て</rt></ruby>をとって <ruby>連<rt>つ</rt></ruby>れてって',
          romaji: 'Te wo totte tsuretette',
          translation: '牵起我的手 带我过去吧',
        ),
      ),
      LyricLine(
        id: 'wim-15',
        startTimeMs: 90690,
        endTimeMs: 93350,
        text: LyricText(
          original: '苺の乗ったショートケーキ',
          ruby: '<ruby>苺<rt>いちご</rt></ruby>の<ruby>乗<rt>の</rt></ruby>ったショートケーキ',
          romaji: 'Ichigo no notta shootokeeki',
          translation: '缀着草莓的鲜奶油蛋糕',
        ),
      ),
      LyricLine(
        id: 'wim-16',
        startTimeMs: 93350,
        endTimeMs: 96140,
        text: LyricText(
          original: 'こだわり卵のとろけるプリン',
          ruby: '<ruby>卵<rt>たまご</rt></ruby>のとろけるプリン',
          romaji: 'Kodawari tamago no torokeru purin',
          translation: '严选鸡蛋做成的入口即化布丁',
        ),
      ),
      LyricLine(
        id: 'wim-17',
        startTimeMs: 96140,
        endTimeMs: 98750,
        text: LyricText(
          original: 'みんなみんな我慢します',
          ruby: 'みんなみんな<ruby>我慢<rt>がまん</rt></ruby>します',
          romaji: 'Minna minna gaman shimasu',
          translation: '这些我都全部忍住不吃啦',
        ),
      ),
      LyricLine(
        id: 'wim-18',
        startTimeMs: 98750,
        endTimeMs: 101500,
        text: LyricText(
          original: 'わがままな子だと思わないで',
          ruby: 'わがままな<ruby>子<rt>こ</rt></ruby>だと<ruby>思<rt>おも</rt></ruby>わないで',
          romaji: 'Wagamama na ko da to omowanaide',
          translation: '请不要把我当成任性的孩子',
        ),
      ),
      LyricLine(
        id: 'wim-19',
        startTimeMs: 101500,
        endTimeMs: 106810,
        text: LyricText(
          original: 'わたしだってやればできるもん あとで後悔するわよ',
          ruby:
              'わたしだってやればできるもん あとで<ruby>後悔<rt>こうかい</rt></ruby>するわよ',
          romaji: 'Watashi datte yareba dekiru mon ato de koukai suru wa yo',
          translation: '我也是只要做就能做到的 到时候可别后悔哦',
        ),
      ),
      LyricLine(
        id: 'wim-20',
        startTimeMs: 106810,
        endTimeMs: 109450,
        text: LyricText(
          original: '当然です だってわたしは',
          ruby: '<ruby>当然<rt>とうぜん</rt></ruby>です だってわたしは',
          romaji: 'Touzen desu datte watashi wa',
          translation: '那是当然的 因为我是——',
        ),
      ),
      LyricLine(
        id: 'wim-21',
        startTimeMs: 109450,
        endTimeMs: 112700,
        text: LyricText(
          original: '世界で一番 おひめさま',
          ruby:
              '<ruby>世界<rt>せかい</rt></ruby>で<ruby>一番<rt>いちばん</rt></ruby> おひめさま',
          romaji: 'Sekai de ichiban ohimesama',
          translation: '世界第一的公主殿下',
        ),
      ),
      LyricLine(
        id: 'wim-22',
        startTimeMs: 112700,
        endTimeMs: 117910,
        text: LyricText(
          original: 'ちゃんと見ててよ どっかに行っちゃうよ？',
          ruby:
              'ちゃんと<ruby>見<rt>み</rt></ruby>ててよ どっかに<ruby>行<rt>い</rt></ruby>っちゃうよ？',
          romaji: 'Chanto mitete yo dokka ni itchau yo?',
          translation: '要好好看着我哦 不然我就跑去别的地方了？',
        ),
      ),
      LyricLine(
        id: 'wim-23',
        startTimeMs: 117910,
        endTimeMs: 123030,
        text: LyricText(
          original: 'ふいに抱きしめられた 急に そんな えっ？',
          ruby:
              'ふいに<ruby>抱<rt>だ</rt></ruby>きしめられた <ruby>急<rt>きゅう</rt></ruby>に そんな えっ？',
          romaji: 'Fui ni dakishimerareta kyuu ni sonna e?',
          translation: '忽然被紧紧抱住 这么突然 欸？',
        ),
      ),
      LyricLine(
        id: 'wim-24',
        startTimeMs: 123030,
        endTimeMs: 125530,
        text: LyricText(
          original: '「轢かれる 危ないよ」',
          ruby: '「<ruby>轢<rt>ひ</rt></ruby>かれる <ruby>危<rt>あぶ</rt></ruby>ないよ」',
          romaji: '"Hikareru abunai yo"',
          translation: '“会被撞到的 很危险哦”',
        ),
      ),
      LyricLine(
        id: 'wim-25',
        startTimeMs: 125530,
        endTimeMs: 127700,
        text: LyricText(
          original: 'そう言ってそっぽ向くキミ',
          ruby:
              'そう<ruby>言<rt>い</rt></ruby>ってそっぽ<ruby>向<rt>む</rt></ruby>くキミ',
          romaji: 'Sou itte soppo muku kimi',
          translation: '这么说着却别过脸去的你',
        ),
      ),
      LyricLine(
        id: 'wim-26',
        startTimeMs: 127700,
        endTimeMs: 130040,
        text: LyricText(
          original: '…こっちのが危ないわよ',
          ruby: '…こっちのが<ruby>危<rt>あぶ</rt></ruby>ないわよ',
          romaji: '...kocchi no ga abunai wa yo',
          translation: '…明明你这样才更让人心动危险嘛',
        ),
      ),
      LyricLine(
        id: 'wim-27',
        startTimeMs: 130040,
        endTimeMs: 134760,
        text: LyricText(
          original: 'ああ！',
          ruby: 'ああ！',
          romaji: 'Aa!',
          translation: '啊啊！',
        ),
      ),
      LyricLine(
        id: 'wim-28',
        startTimeMs: 134760,
        endTimeMs: 139040,
        text: LyricText(
          original: 'でもね ちょっとだけ 心が揺れる',
          ruby:
              'でもね ちょっとだけ <ruby>心<rt>こころ</rt></ruby>が<ruby>揺<rt>ゆ</rt></ruby>れる',
          romaji: 'Demo ne chotto dake kokoro ga yureru',
          translation: '不过呢 心中也稍微动摇了一点点',
        ),
      ),
      LyricLine(
        id: 'wim-29',
        startTimeMs: 139040,
        endTimeMs: 143380,
        text: LyricText(
          original: 'こんな時はやっぱり お姫様扱いしてよね',
          ruby:
              'こんな<ruby>時<rt>とき</rt></ruby>はやっぱり お<ruby>姫様<rt>ひめさま</rt></ruby><ruby>扱<rt>あつか</rt></ruby>いしてよね',
          romaji: 'Konna toki wa yappari ohimesama atsukai shite yo ne',
          translation: '这种时候 果然还是应该把我当成公主殿下哄才对嘛',
        ),
      ),
      LyricLine(
        id: 'wim-30',
        startTimeMs: 143380,
        endTimeMs: 147460,
        text: LyricText(
          original: 'だって 世界で一番',
          ruby:
              'だって <ruby>世界<rt>せかい</rt></ruby>で<ruby>一番<rt>いちばん</rt></ruby>',
          romaji: 'Datte sekai de ichiban',
          translation: '因为我是 世界第一的——',
        ),
      ),
      LyricLine(
        id: 'wim-31',
        startTimeMs: 147460,
        endTimeMs: 151800,
        text: LyricText(
          original: '手をとって 連れてって',
          ruby: '<ruby>手<rt>て</rt></ruby>をとって <ruby>連<rt>つ</rt></ruby>れてって',
          romaji: 'Te wo totte tsuretette',
          translation: '牵起我的手 带我前往未来吧',
        ),
      ),
      LyricLine(
        id: 'wim-32',
        startTimeMs: 171340,
        endTimeMs: 174310,
        text: LyricText(
          original: '欠点？かわいいの間違いでしょ',
          ruby:
              '<ruby>欠点<rt>けってん</rt></ruby>？かわいいの<ruby>間違<rt>まちが</rt></ruby>いでしょ',
          romaji: 'Ketten? Kawaii no machigai desho',
          translation: '缺点？那肯定是可爱的同义词搞错了吧',
        ),
      ),
      LyricLine(
        id: 'wim-33',
        startTimeMs: 174310,
        endTimeMs: 177130,
        text: LyricText(
          original: '文句は許しませんの',
          ruby: '<ruby>文句<rt>もんく</rt></ruby>は<ruby>許<rt>ゆる</rt></ruby>しませんの',
          romaji: 'Monku wa yurushimasen no',
          translation: '可不允许有任何抱怨哦',
        ),
      ),
      LyricLine(
        id: 'wim-34',
        startTimeMs: 177130,
        endTimeMs: 179870,
        text: LyricText(
          original: 'あのね？わたしの話ちゃんと聞いてる？ちょっとぉ',
          ruby:
              'あのね？わたしの<ruby>話<rt>はなし</rt></ruby>ちゃんと<ruby>聞<rt>き</rt></ruby>いてる？ちょっとぉ',
          romaji: 'Ano ne? Watashi no hanashi chanto kiiteru? Chottoo',
          translation: '我说啊 你到底有没有认真听我说话呀？喂——',
        ),
      ),
      LyricLine(
        id: 'wim-35',
        startTimeMs: 179870,
        endTimeMs: 182760,
        text: LyricText(
          original: 'あ、それとね？白いお馬さん決まってるでしょ？迎えにきて',
          ruby:
              'あ、それとね？<ruby>白<rt>しろ</rt></ruby>いお<ruby>馬<rt>うま</rt></ruby>さん<ruby>決<rt>き</rt></ruby>まってるでしょ？<ruby>迎<rt>むか</rt></ruby>えにきて',
          romaji: 'A, sore to ne? Shiroi oumasan kimatteru desho? Mukae ni kite',
          translation: '啊 还有啊？白马当然也准备好了吧？快来迎接我呀',
        ),
      ),
      LyricLine(
        id: 'wim-36',
        startTimeMs: 182760,
        endTimeMs: 187710,
        text: LyricText(
          original: 'わかったらかしずいて 手を取って「お姫様」って',
          ruby:
              'わかったらかしずいて <ruby>手<rt>て</rt></ruby>を<ruby>取<rt>と</rt></ruby>って「お<ruby>姫様<rt>ひめさま</rt></ruby>」って',
          romaji: 'Wakattara kashizuite te wo totte "Ohimesama" tte',
          translation: '知道了就单膝跪下 牵起我的手叫一声「公主殿下」吧',
        ),
      ),
      LyricLine(
        id: 'wim-37',
        startTimeMs: 187710,
        endTimeMs: 192360,
        text: LyricText(
          original: 'べつに わがままなんて言ってないんだから',
          ruby:
              'べつに わがままなんて<ruby>言<rt>い</rt></ruby>ってないんだから',
          romaji: 'Betsu ni wagamama nante ittenain da kara',
          translation: '人家才没有在耍任性呢',
        ),
      ),
      LyricLine(
        id: 'wim-38',
        startTimeMs: 192360,
        endTimeMs: 196840,
        text: LyricText(
          original: 'でもね ちょっとくらい 叱ってくれたっていいのよ？',
          ruby:
              'でもね ちょっとくらい <ruby>叱<rt>しか</rt></ruby>ってくれたっていいのよ？',
          romaji: 'Demo ne chotto kurai shikatte kuretatte ii no yo?',
          translation: '不过呢 稍微责备一下我其实也没关系哦？',
        ),
      ),
      LyricLine(
        id: 'wim-39',
        startTimeMs: 196840,
        endTimeMs: 201010,
        text: LyricText(
          original: '世界で一番 あたしだけのおうじさま',
          ruby:
              '<ruby>世界<rt>せかい</rt></ruby>で<ruby>一番<rt>いちばん</rt></ruby> あたしだけのおうじさま',
          romaji: 'Sekai de ichiban atashi dake no oujisama',
          translation: '世界上最棒的 只属于我一人的王子殿下',
        ),
      ),
      LyricLine(
        id: 'wim-40',
        startTimeMs: 201010,
        endTimeMs: 203370,
        text: LyricText(
          original: '気がついて ほらほら あんよが空いてます',
          ruby:
              '<ruby>気<rt>き</rt></ruby>がついて ほらほら あんよが<ruby>空<rt>あ</rt></ruby>いてます',
          romaji: 'Ki ga tsuite hora hora anyo ga aitemasu',
          translation: '快注意到呀 瞧一瞧 我的舞步还空着呢',
        ),
      ),
      LyricLine(
        id: 'wim-41',
        startTimeMs: 203370,
        endTimeMs: 208090,
        text: LyricText(
          original: '無口で無愛想なおうじさま',
          ruby:
              '<ruby>無口<rt>むくち</rt></ruby>で<ruby>無愛想<rt>ぶあいそう</rt></ruby>なおうじさま',
          romaji: 'Mukuchi de buaisou na oujisama',
          translation: '沉默寡言又不爱笑的王子殿下',
        ),
      ),
      LyricLine(
        id: 'wim-42',
        startTimeMs: 208090,
        endTimeMs: 212420,
        text: LyricText(
          original: 'もう！どうして！気がついてよ早く',
          ruby:
              'もう！どうして！<ruby>気<rt>き</rt></ruby>がついてよ<ruby>早<rt>はや</rt></ruby>く',
          romaji: 'Mou! Doushite! Ki ga tsuite yo hayaku',
          translation: '真是的！为什么呀！快点察觉我的心意嘛',
        ),
      ),
      LyricLine(
        id: 'wim-43',
        startTimeMs: 212420,
        endTimeMs: 216710,
        text: LyricText(
          original: 'ぜったいキミはわかってない！わかってないわ',
          ruby:
              'ぜったいキミはわかってない！わかってないわ',
          romaji: 'Zettai kimi wa wakattenai! Wakattenai wa',
          translation: '你绝对什么都还不懂！完全不懂嘛',
        ),
      ),
      LyricLine(
        id: 'wim-44',
        startTimeMs: 216710,
        endTimeMs: 220830,
        text: LyricText(
          original: 'もう、どうしてよ！',
          ruby: 'もう、どうしてよ！',
          romaji: 'Mou, doushite yo!',
          translation: '哼，到底是怎么回事呀！',
        ),
      ),
      LyricLine(
        id: 'wim-45',
        startTimeMs: 220830,
        endTimeMs: 225200,
        text: LyricText(
          original: '手をとって 連れてって',
          ruby: '<ruby>手<rt>て</rt></ruby>をとって <ruby>連<rt>つ</rt></ruby>れてって',
          romaji: 'Te wo totte tsuretette',
          translation: '牵起我的手 带我前往未来吧',
        ),
      ),
      LyricLine(
        id: 'wim-46',
        startTimeMs: 234390,
        endTimeMs: 240010,
        text: LyricText(
          original: '世界で一番 おひめさま',
          ruby:
              '<ruby>世界<rt>せかい</rt></ruby>で<ruby>一番<rt>いちばん</rt></ruby> おひめさま',
          romaji: 'Sekai de ichiban ohimesama',
          translation: '世界第一的公主殿下',
        ),
      ),
      LyricLine(
        id: 'wim-47',
        startTimeMs: 240010,
        endTimeMs: 241410,
        text: LyricText(
          original: 'ちゃんとしつけといてよね？',
          ruby: 'ちゃんとしつけといてよね？',
          romaji: 'Chanto shitsuketoite yo ne?',
          translation: '要好好哄好这位任性公主哦？',
        ),
      ),
      LyricLine(
        id: 'wim-48',
        startTimeMs: 241410,
        endTimeMs: 243750,
        text: LyricText(
          original: 'Ah!',
          ruby: 'Ah!',
          romaji: 'Ah!',
          translation: 'Ah!',
        ),
      ),
    ],
  ),
);
