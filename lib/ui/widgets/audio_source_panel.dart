import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:prism_ui/icons/icons.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../state/callbook_controller.dart';
import 'archive_switcher_dialog.dart';
import 'callbook_glyphs.dart';

Future<void> showAudioSourceModal(
  BuildContext context,
  CallbookController controller,
) async {
  await showFloatingDialog<void>(
    context: context,
    child: Builder(
      builder: (dialogCtx) => AlertDialog(
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
    ('demo', '内置 Demo'),
  ];

  static const List<(String, String)> _providers = [
    ('auto', '自动聚合'),
    ('custom_proxy', '网易云直连'),
    ('lrclib', 'LRCLIB'),
    ('mock', '演示库'),
  ];

  String _sourceTab = 'search';
  String _searchSource = 'auto';
  bool _forceJapaneseRuby = true;
  bool _showTranslationBox = false;
  bool _parsingLrc = false;

  final TextEditingController _searchCtrl = TextEditingController(
    text: 'Starlight',
  );
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
                label: c.backendOnline ? '服务在线' : '纯 Dart 直连',
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
        const SizedBox(height: 12),
        if (_sourceTab == 'search') _buildSearchTab(context, c, scheme),
        if (_sourceTab == 'local') _buildLocalTab(context, c, scheme),
        if (_sourceTab == 'demo') _buildDemoTab(context, c, scheme),
      ],
    );

    if (widget.modalMode) {
      return body;
    }

    return Card(
      inert: true,
      radius: 22,
      padding: const EdgeInsets.all(14),
      child: body,
    );
  }

  Widget _buildSearchTab(
    BuildContext context,
    CallbookController c,
    ColorScheme scheme,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final (id, label) in _providers)
              TonalChip(
                label: label,
                color: _searchSource == id
                    ? scheme.primaryContainer
                    : scheme.surfaceContainerHigh,
                foregroundColor: _searchSource == id
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant,
                onPressed: () => setState(() => _searchSource = id),
              ),
          ],
        ),
        if (_searchSource == 'custom_proxy' &&
            !c.gatewayStatus.cookieConfigured &&
            !c.gatewayStatus.gatewayOnline &&
            !c.customProxyEnabled) ...[
          const SizedBox(height: 6),
          Text(
            '纯 Dart 直连网易云已就绪（游客模式可直接检索公开曲目与歌词；如需 VIP/完整音源可在下方粘贴 Cookie）。',
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
        if (c.searchResults.isNotEmpty) ...[
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
              child: GestureDetector(
                onTap: () =>
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

  Widget _buildDemoTab(
    BuildContext context,
    CallbookController c,
    ColorScheme scheme,
  ) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: ShapeDecoration(
        color: scheme.surfaceContainerLow,
        shape: AppShape.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GlyphIcon(
                CallbookGlyphs.musicNote,
                size: 16,
                color: scheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '使用内置节拍合成引擎播放 175 BPM 无版权鼓点与演示歌词，适合离线测试节拍同步与编写演练。',
                  style: AppTextStyle.caption1.of(context).copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: () async {
              final ok = await confirmArchiveSaveIfNeeded(
                context,
                c,
                actionLabel: '加载演练 Demo',
                targetLabel: '175 BPM 合成 Demo',
              );
              if (!ok || !mounted) return;
              await c.loadDemoProject();
              if (mounted) {
                widget.onImported?.call();
              }
            },
            child: const Text('加载 175 BPM 演示曲目'),
          ),
        ],
      ),
    );
  }
}
