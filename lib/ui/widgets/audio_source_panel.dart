import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:prism_ui/icons/icons.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../data/default_songs.dart';
import '../../state/callbook_controller.dart';
import '../theme/app_tokens.dart';
import 'archive_switcher_dialog.dart';
import 'app_dialog.dart';
import 'callbook_glyphs.dart';

Future<void> showAudioSourceModal(
  BuildContext context,
  CallbookController controller,
) async {
  await showAppAdaptiveSheetOrDialog<void>(
    context: context,
    dialogBuilder: (dialogCtx) => AlertDialog(
      title: '音源与歌词导入',
      hasFields: true,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogCtx).pop(),
          child: const Text('关闭'),
        ),
      ],
      child: SizedBox(
        width: 460,
        child: AudioSourcePanel(
          controller: controller,
          modalMode: true,
          onImported: () {
            if (dialogCtx.mounted) {
              Navigator.of(dialogCtx).pop();
            }
          },
        ),
      ),
    ),
    sheetBuilder: (sheetCtx, scrollController) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SheetDragHandle(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '音源与歌词导入',
                  style: AppTextStyle.headline
                      .of(sheetCtx, emphasized: true)
                      .copyWith(color: sheetCtx.colorScheme.onSurface),
                ),
              ),
              Semantics(
                button: true,
                label: '关闭音源面板',
                child: IconButton(
                  tooltip: '关闭',
                  icon: const GlyphIcon(Glyphs.close, size: 18),
                  style: const ButtonStyle(
                    minimumSize: AppTokens.minTapTargetSize,
                  ),
                  onPressed: () => Navigator.of(sheetCtx).pop(),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: SingleChildScrollView(
            controller: scrollController,
            padding: const EdgeInsets.all(AppTokens.s16),
            child: AudioSourcePanel(
              controller: controller,
              modalMode: true,
              onImported: () {
                if (sheetCtx.mounted) {
                  Navigator.of(sheetCtx).pop();
                }
              },
            ),
          ),
        ),
      ],
    ),
  );
}

class AudioSourcePanel extends StatefulWidget {
  const AudioSourcePanel({
    super.key,
    required this.controller,
    this.modalMode = false,
    this.onImported,
  });

  final CallbookController controller;
  final bool modalMode;
  final VoidCallback? onImported;

  @override
  State<AudioSourcePanel> createState() => _AudioSourcePanelState();
}

class _AudioSourcePanelState extends State<AudioSourcePanel> {
  static const List<(String, String)> _tabs = [
    ('search', '搜索曲库'),
    ('local', '本地音轨 + LRC'),
    ('defaults', '默认曲库'),
  ];

  static const List<(String, String)> _providers = [
    ('auto', '自动聚合'),
    ('custom_proxy', '网易云直连'),
    ('lrclib', 'LRCLIB'),
  ];

  String _sourceTab = 'search';
  String _searchSource = 'auto';
  bool _forceJapaneseRuby = true;
  bool _showTranslationBox = false;
  bool _parsingLrc = false;

  final TextEditingController _searchCtrl = TextEditingController();
  final TextEditingController _lrcCtrl = TextEditingController();
  final TextEditingController _transCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    _lrcCtrl.dispose();
    _transCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickLocalAudio() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.audio,
      withData: false,
    );
    if (res == null || res.files.isEmpty) return;
    final file = res.files.first;
    final path = file.path;
    if (path != null && path.isNotEmpty) {
      await widget.controller.loadLocalAudioFile(path, file.name);
      if (mounted) {
        widget.onImported?.call();
      }
    }
  }

  Future<void> _handleParseLrc() async {
    if (_lrcCtrl.text.trim().isEmpty || _parsingLrc) return;
    final c = widget.controller;
    final ok = await confirmArchiveSaveIfNeeded(
      context,
      c,
      actionLabel: '导入新 LRC 歌词',
    );
    if (!ok || !mounted) return;
    setState(() => _parsingLrc = true);
    try {
      await c.importLrcText(
        lrc: _lrcCtrl.text,
        translationLrc: _transCtrl.text,
        enableRuby: _forceJapaneseRuby,
      );
      if (mounted) {
        widget.onImported?.call();
      }
    } finally {
      if (mounted) {
        setState(() => _parsingLrc = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final scheme = context.colorScheme;

    return ListenableBuilder(
      listenable: Listenable.merge([c.gatewayListenable, c.projectListenable]),
      builder: (context, _) {
        final body = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!widget.modalMode) ...[
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '音源与歌词导入',
                      style: AppTextStyle.headline
                          .of(context, emphasized: true)
                          .copyWith(color: scheme.onSurface),
                    ),
                  ),
                  TonalChip(
                    label: c.backendOnline ? '服务在线' : '直接连接',
                    color: c.backendOnline
                        ? scheme.successContainer
                        : scheme.primaryContainer,
                    foregroundColor: c.backendOnline
                        ? scheme.onSuccessContainer
                        : scheme.onPrimaryContainer,
                  ),
                ],
              ),
              const SizedBox(height: 10),
            ],
            SegmentedControl<String>(
              segments: _tabs,
              value: _sourceTab,
              onChanged: (v) => setState(() => _sourceTab = v),
            ),
            if (c.hasRestorableCreditLines) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: ShapeDecoration(
                  color: scheme.secondaryContainer.withValues(alpha: 0.65),
                  shape: AppShape.md,
                ),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '已过滤 ${c.restorableCreditLines.length} 行片头制作信息',
                      style: AppTextStyle.caption1.of(context).copyWith(
                        color: scheme.onSecondaryContainer,
                      ),
                    ),
                    TonalChip(
                      label: '恢复被过滤的制作信息行',
                      color: scheme.primaryContainer,
                      foregroundColor: scheme.onPrimaryContainer,
                      onPressed: () => c.restoreFilteredCreditLines(),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            if (_sourceTab == 'search') _buildSearchTab(context, c, scheme),
            if (_sourceTab == 'local') _buildLocalTab(context, c, scheme),
            if (_sourceTab == 'defaults')
              _buildDefaultSongsTab(context, c, scheme),
          ],
        );

        if (widget.modalMode) {
          return body;
        }

        return Card(
          inert: true,
          radius: AppTokens.radiusCard,
          padding: const EdgeInsets.all(14),
          child: body,
        );
      },
    );
  }

  Widget _buildSearchTab(
    BuildContext context,
    CallbookController c,
    ColorScheme scheme,
  ) {
    final loadingSkeleton = c.isSearching || c.isFetchingLyrics;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SegmentedControl<String>(
          segments: _providers,
          value: _searchSource,
          onChanged: (v) => setState(() => _searchSource = v),
        ),
        if (_searchSource == 'custom_proxy' &&
            !c.gatewayStatus.cookieConfigured &&
            !c.gatewayStatus.gatewayOnline &&
            !c.customProxyEnabled) ...[
          const SizedBox(height: 6),
          Text(
            '直接连接网易云已就绪（游客模式可直接检索公开曲目与歌词；如需 VIP/完整音源可在下方粘贴 Cookie）。',
            style: AppTextStyle.caption1.of(context).copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _searchCtrl,
                decoration: const InputDecoration(
                  hintText: '输入歌名或歌手...',
                ),
                onSubmitted: (q) => c.searchTracks(q, source: _searchSource),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: c.isSearching
                  ? null
                  : () => c.searchTracks(
                      _searchCtrl.text,
                      source: _searchSource,
                    ),
              child: Text(c.isSearching ? '检索...' : '搜索'),
            ),
          ],
        ),
        if (loadingSkeleton) ...[
          const SizedBox(height: 10),
          for (var i = 0; i < 3; i++)
            Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 10,
              ),
              decoration: ShapeDecoration(
                color: scheme.surfaceContainerLow,
                shape: AppShape.lg,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonText(
                    width: i == 1 ? 180 : 140,
                    style: AppTextStyle.subheadline.of(context),
                  ),
                  const SizedBox(height: 6),
                  SkeletonText(
                    width: 110,
                    style: AppTextStyle.caption1.of(context),
                  ),
                ],
              ),
            ),
        ] else if (c.searchResults.isNotEmpty) ...[
          const SizedBox(height: 10),
          for (final track in c.searchResults.take(widget.modalMode ? 6 : 5))
            Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
              ),
              decoration: ShapeDecoration(
                color: scheme.surfaceContainerLow,
                shape: AppShape.lg,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyle.subheadline
                              .of(context, emphasized: true)
                              .copyWith(color: scheme.onSurface),
                        ),
                        Text(
                          '${track.artist} · ${track.platform}${track.bpm != null ? " · ${track.bpm} BPM" : ""}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyle.caption1.of(context).copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  TonalChip(
                    label: '导入',
                    color: scheme.primaryContainer,
                    foregroundColor: scheme.onPrimaryContainer,
                    onPressed: () async {
                      final ok = await confirmArchiveSaveIfNeeded(
                        context,
                        c,
                        actionLabel: '拉取新曲目歌词',
                        targetLabel: track.title,
                      );
                      if (!ok || !mounted) return;
                      await c.loadRemoteTrack(track);
                      if (mounted) {
                        widget.onImported?.call();
                      }
                    },
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }

  Widget _buildLocalTab(
    BuildContext context,
    CallbookController c,
    ColorScheme scheme,
  ) {
    final introSec = (c.sectionThresholds.introThresholdMs / 1000).round();
    final interSec = (c.sectionThresholds.interludeThresholdMs / 1000).round();
    final outroSec = (c.sectionThresholds.outroThresholdMs / 1000).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        TonalButton(
          size: TonalButtonSize.compact,
          glyph: CallbookGlyphs.musicNote,
          label: '选择本地音频 (MP3/WAV/FLAC)',
          onPressed: _pickLocalAudio,
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _lrcCtrl,
          maxLines: 4,
          minLines: 3,
          decoration: const InputDecoration(
            hintText: '粘贴 LRC 歌词：[00:12.34]歌詞...',
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: PressSurface(
                fill: const Color(0x00000000),
                shape: AppShape.sm,
                tapTarget: AppTokens.minTapTargetSize,
                onPressed: () =>
                    setState(() => _forceJapaneseRuby = !_forceJapaneseRuby),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Switch(
                      value: _forceJapaneseRuby,
                      onChanged: (v) =>
                          setState(() => _forceJapaneseRuby = v),
                      semanticLabel: '强制日语注音',
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        '强制日语注音',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyle.caption1.of(context).copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            TextButton(
              onPressed: () =>
                  setState(() => _showTranslationBox = !_showTranslationBox),
              child: Text(_showTranslationBox ? '收起翻译框' : '+ 中文翻译 LRC'),
            ),
          ],
        ),
        PressSurface(
          fill: const Color(0x00000000),
          shape: AppShape.sm,
          tapTarget: AppTokens.minTapTargetSize,
          onPressed: () => c.setFilterLrcHeaderCredits(!c.filterLrcHeaderCredits),
          child: Row(
            children: [
              Switch(
                value: c.filterLrcHeaderCredits,
                onChanged: c.setFilterLrcHeaderCredits,
                semanticLabel: '过滤片头制作信息',
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '过滤片头制作信息（仅前 10 行且在前 20 秒内）',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyle.caption1.of(context).copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_showTranslationBox) ...[
          const SizedBox(height: 6),
          TextField(
            controller: _transCtrl,
            maxLines: 2,
            minLines: 2,
            decoration: const InputDecoration(
              hintText: '粘贴中文翻译 LRC（按时间戳对齐）',
            ),
          ),
        ],
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: ShapeDecoration(
            color: scheme.surfaceContainerLow,
            shape: AppShape.md,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '导入后将自动识别前奏 / 间奏 / 尾奏',
                  style: AppTextStyle.caption2.of(context).copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              Text(
                '${introSec}s / ${interSec}s / ${outroSec}s',
                style: AppTextStyle.caption2.of(context, emphasized: true)
                    .copyWith(
                      fontFamily: 'GoogleSans',
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        FilledButton(
          onPressed: _parsingLrc ? null : _handleParseLrc,
          child: Text(_parsingLrc ? '解析中...' : '解析并导入歌词'),
        ),
      ],
    );
  }

  Widget _buildDefaultSongsTab(
    BuildContext context,
    CallbookController c,
    ColorScheme scheme,
  ) {
    final activeSpec = findDefaultSongByProject(c.project);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '内置 3 首无预设 Call 的精选模板曲目，载入后会尝试自动匹配在线试听音源，亦可配合节拍器直接编写演练。',
          style: AppTextStyle.caption1.of(context).copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 10),
        for (var i = 0; i < defaultSongs.length; i++) ...[
          (() {
            final spec = defaultSongs[i];
            final isCurrent = activeSpec?.id == spec.id;
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: ShapeDecoration(
                color: isCurrent
                    ? scheme.primaryContainer.withValues(alpha: 0.45)
                    : scheme.surfaceContainerLow,
                shape: RoundedSuperellipseBorder(
                  borderRadius: AppRadius.lg,
                  side: isCurrent
                      ? BorderSide(color: scheme.primary, width: 1.5)
                      : BorderSide(color: scheme.outlineVariant),
                ),
              ),
              child: Row(
                children: [
                  GlyphIcon(
                    CallbookGlyphs.musicNote,
                    size: 16,
                    color: isCurrent ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          spec.project.meta.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyle.subheadline
                              .of(context, emphasized: true)
                              .copyWith(color: scheme.onSurface),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          spec.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyle.caption1.of(context).copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  TonalChip(
                    label: isCurrent ? '重新载入' : '载入曲目',
                    color: isCurrent
                        ? scheme.primary
                        : scheme.primaryContainer,
                    foregroundColor: isCurrent
                        ? scheme.onPrimary
                        : scheme.onPrimaryContainer,
                    onPressed: () async {
                      final ok = await confirmArchiveSaveIfNeeded(
                        context,
                        c,
                        actionLabel: '切换默认曲目',
                        targetLabel: spec.project.meta.title,
                      );
                      if (!ok || !mounted) return;
                      await c.loadDefaultSong(spec.id);
                      if (mounted) {
                        widget.onImported?.call();
                      }
                    },
                  ),
                ],
              ),
            );
          })(),
          if (i < defaultSongs.length - 1) const SizedBox(height: 8),
        ],
      ],
    );
  }
}
