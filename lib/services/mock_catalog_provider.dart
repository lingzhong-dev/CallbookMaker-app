import '../models/callbook_models.dart';
import '../utils/lrc_ruby_parser.dart';

class _MockCatalogEntry {
  const _MockCatalogEntry({
    required this.summary,
    required this.rawLrc,
    required this.translatedLrc,
  });

  final TrackSummary summary;
  final String rawLrc;
  final String translatedLrc;
}

/// Built-in offline fallback provider with copyright-free synthetic demo tracks
/// matching the CallbookMaker-Web mock catalog.
class MockCatalogProvider {
  const MockCatalogProvider();

  static const List<_MockCatalogEntry> _catalog = [
    _MockCatalogEntry(
      summary: TrackSummary(
        id: 'mock-starlight-175',
        platform: 'synthetic',
        title: 'Starlight Overdrive (175 BPM Demo)',
        artist: 'Synthetic Stage Unit',
        album: 'Open Source Call Demo Vol.1',
        durationMs: 48000,
        bpm: 175,
        hasSyncedLyrics: true,
        hasAudioUrl: false,
        provider: 'mock',
      ),
      rawLrc: '''[00:01.37]夜空を見上げて 響けメロディ
[00:04.11]高鳴る鼓動が 今 始まる
[00:06.85]光の中へ 駆け出そうよ
[00:09.60]僕らの声で 未来を描こう
[00:12.34]手を伸ばしたら 届くはずさ
[00:15.08]輝くステージ 夢の向こうへ
[00:17.82]全力で叫べ 熱い想い
[00:20.57]ひとつになる瞬間 忘れないで''',
      translatedLrc: '''[00:01.37]仰望夜空 让旋律回响吧
[00:04.11]沸腾的心跳 此刻正式开启
[00:06.85]向着光芒之中 一起奔跑吧
[00:09.60]用我们的声音 描绘出未来
[00:12.34]只要伸出双手 就一定能触及
[00:15.08]闪耀的舞台 去往梦想的彼岸
[00:17.82]全力呐喊吧 炽热的心意
[00:20.57]融为一体的瞬间 请不要忘记''',
    ),
    _MockCatalogEntry(
      summary: TrackSummary(
        id: 'mock-aozora-160',
        platform: 'synthetic',
        title: '青空エール (160 BPM Demo)',
        artist: 'Live Practice Synth',
        album: 'Open Source Call Demo Vol.1',
        durationMs: 42000,
        bpm: 160,
        hasSyncedLyrics: true,
        hasAudioUrl: false,
        provider: 'mock',
      ),
      rawLrc: '''[00:01.50]青い空の下 風を感じて
[00:04.50]笑顔の約束 ここに集まる
[00:07.50]リズムに合わせて 飛び跳ねよう
[00:10.50]明日の扉を 開く合図だ
[00:13.50]止まらない声援 空に届け
[00:16.50]ずっとこの場所で 歌い続ける''',
      translatedLrc: '''[00:01.50]在蔚蓝天空下 感受微风拂过
[00:04.50]带着笑容的约定 在此汇聚
[00:07.50]配合着节奏 一起纵情跳跃吧
[00:10.50]这是开启明日之门的信号
[00:13.50]永不止息的应援 传向天空吧
[00:16.50]永远在这个地方 继续歌唱下去''',
    ),
    _MockCatalogEntry(
      summary: TrackSummary(
        id: 'mock-neon-140',
        platform: 'synthetic',
        title: 'Neon Pulse Anthem (140 BPM Demo)',
        artist: 'Open Call Collective',
        album: 'Practice Pack',
        durationMs: 36000,
        bpm: 140,
        hasSyncedLyrics: true,
        hasAudioUrl: false,
        provider: 'mock',
      ),
      rawLrc: '''[00:01.71]星屑の海を 越えてゆこう
[00:05.14]白いペンライト 揺れる景色
[00:08.57]カウントゼロで 飛び立つ準備
[00:12.00]奇跡のステージ 今ここに''',
      translatedLrc: '''[00:01.71]跨越星屑之海 一同前行吧
[00:05.14]白色荧光棒 摇曳的风景
[00:08.57]倒数归零 做好起飞的准备
[00:12.00]奇迹的舞台 此刻就在这里''',
    ),
  ];

  List<TrackSummary> searchTracks(String query, {int limit = 10}) {
    final q = query.trim().toLowerCase();
    final all = [for (final item in _catalog) item.summary];
    if (q.isEmpty ||
        q == 'demo' ||
        q == 'mock' ||
        q == 'call' ||
        q == 'live' ||
        q == 'test') {
      return all.take(limit).toList();
    }
    final matched = [
      for (final s in all)
        if (s.title.toLowerCase().contains(q) ||
            s.artist.toLowerCase().contains(q) ||
            s.album.toLowerCase().contains(q))
          s,
    ];
    return (matched.isNotEmpty ? matched : all).take(limit).toList();
  }

  TrackDetailResponse? fetchTrackDetail(String trackId) {
    for (final item in _catalog) {
      if (item.summary.id == trackId) {
        return TrackDetailResponse(
          track: item.summary,
          audioUrl: '',
          rawLrc: item.rawLrc,
          translatedLrc: item.translatedLrc,
          lines: parseLrcOffline(
            item.rawLrc,
            translationLrc: item.translatedLrc,
          ),
        );
      }
    }
    return null;
  }
}
