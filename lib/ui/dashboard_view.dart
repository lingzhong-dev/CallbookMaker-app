import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:prism_ui/icons/icons.dart';
import 'package:prism_ui/prism_ui.dart';

import '../state/callbook_controller.dart';
import '../utils/lrc_ruby_parser.dart';
import 'widgets/audio_source_panel.dart';
import 'widgets/callbook_glyphs.dart';
import 'widgets/line_sparkline.dart';
import 'widgets/scalloped_orb_button.dart';
import 'widgets/timeline_editor_widget.dart';

class DashboardView extends StatefulWidget {
  const DashboardView({super.key, required this.controller});

  final CallbookController controller;

  @override
  State<DashboardView> createState() => _DashboardViewState();
}

class _DashboardViewState extends State<DashboardView> {
  final GlobalKey _timelineKey = GlobalKey();

  late final TextEditingController _titleCtrl;
  late final TextEditingController _artistCtrl;
  late final TextEditingController _bpmCtrl;
  late final TextEditingController _composerCtrl;
  late final TextEditingController _lyricistCtrl;
  late final TextEditingController _vocalistCtrl;
  late final TextEditingController _tunerCtrl;
  late final TextEditingController _editorNameCtrl;
  late final TextEditingController _editorNoteCtrl;

  final FocusNode _bpmFocus = FocusNode();
  final FocusNode _composerFocus = FocusNode();
  final FocusNode _lyricistFocus = FocusNode();
  final FocusNode _vocalistFocus = FocusNode();
  final FocusNode _tunerFocus = FocusNode();
  final FocusNode _editorNameFocus = FocusNode();
  final FocusNode _editorNoteFocus = FocusNode();

  late final TextEditingController _backendCtrl;
  late final TextEditingController _gatewayUrlCtrl;
  late final TextEditingController _neteaseCookieCtrl;
  final FocusNode _backendUrlFocus = FocusNode();
  final FocusNode _gatewayUrlFocus = FocusNode();
  final FocusNode _neteaseCookieFocus = FocusNode();
  String _lastSyncedBackendUrl = '';
  String _lastSyncedGatewayUrl = '';
  String _lastSyncedCookie = '';
  bool _obscureCookie = true;
  bool _showOffsetTools = false;
  bool _showGatewayCard = false;
  String _lastSyncedTitle = '';
  String _lastSyncedArtist = '';

  @override
  void initState() {
    super.initState();
    final meta = widget.controller.project.meta;
    _lastSyncedTitle = meta.title;
    _lastSyncedArtist = meta.artist;
    _titleCtrl = TextEditingController(text: _lastSyncedTitle);
    _artistCtrl = TextEditingController(text: _lastSyncedArtist);
    _bpmCtrl = TextEditingController(text: '${meta.bpm}');
    _composerCtrl = TextEditingController(text: meta.composer);
    _lyricistCtrl = TextEditingController(text: meta.lyricist);
    _vocalistCtrl = TextEditingController(text: meta.vocalist);
    _tunerCtrl = TextEditingController(text: meta.tuner);
    _editorNameCtrl = TextEditingController(text: meta.editorName);
    _editorNoteCtrl = TextEditingController(text: meta.editorNote);
    _backendCtrl = TextEditingController(text: widget.controller.backendUrl);
    _gatewayUrlCtrl = TextEditingController(
      text: widget.controller.savedGatewayUrl,
    );
    _neteaseCookieCtrl = TextEditingController(
      text: widget.controller.savedNeteaseCookie,
    );
    _lastSyncedBackendUrl = widget.controller.backendUrl;
    _lastSyncedGatewayUrl = widget.controller.savedGatewayUrl;
    _lastSyncedCookie = widget.controller.savedNeteaseCookie;
    _bpmFocus.addListener(_onBpmFocusChanged);
    widget.controller.addListener(_syncNetworkControllers);
  }

  void _onBpmFocusChanged() {
    if (!_bpmFocus.hasFocus && mounted) {
      _commitBpmInput(widget.controller, _bpmCtrl.text);
    }
  }

  @override
  void didUpdateWidget(covariant DashboardView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncMetaControllers();
  }

  void _syncFieldIfIdle(
    TextEditingController ctrl,
    FocusNode focus,
    String target,
  ) {
    if (!focus.hasFocus && ctrl.text != target) {
      ctrl.text = target;
    }
  }

  void _syncMetaControllers() {
    final meta = widget.controller.project.meta;
    if (meta.title != _lastSyncedTitle && _titleCtrl.text != meta.title) {
      _titleCtrl.text = meta.title;
    }
    _lastSyncedTitle = meta.title;
    if (meta.artist != _lastSyncedArtist && _artistCtrl.text != meta.artist) {
      _artistCtrl.text = meta.artist;
    }
    _lastSyncedArtist = meta.artist;
    _syncFieldIfIdle(_bpmCtrl, _bpmFocus, '${meta.bpm}');
    _syncFieldIfIdle(_composerCtrl, _composerFocus, meta.composer);
    _syncFieldIfIdle(_lyricistCtrl, _lyricistFocus, meta.lyricist);
    _syncFieldIfIdle(_vocalistCtrl, _vocalistFocus, meta.vocalist);
    _syncFieldIfIdle(_tunerCtrl, _tunerFocus, meta.tuner);
    _syncFieldIfIdle(_editorNameCtrl, _editorNameFocus, meta.editorName);
    _syncFieldIfIdle(_editorNoteCtrl, _editorNoteFocus, meta.editorNote);
  }

  @override
  void dispose() {
    _bpmFocus.removeListener(_onBpmFocusChanged);
    _titleCtrl.dispose();
    _artistCtrl.dispose();
    _bpmCtrl.dispose();
    _composerCtrl.dispose();
    _lyricistCtrl.dispose();
    _vocalistCtrl.dispose();
    _tunerCtrl.dispose();
    _editorNameCtrl.dispose();
    _editorNoteCtrl.dispose();
    _bpmFocus.dispose();
    _composerFocus.dispose();
    _lyricistFocus.dispose();
    _vocalistFocus.dispose();
    _tunerFocus.dispose();
    _editorNameFocus.dispose();
    _editorNoteFocus.dispose();
    widget.controller.removeListener(_syncNetworkControllers);
    _backendCtrl.dispose();
    _gatewayUrlCtrl.dispose();
    _neteaseCookieCtrl.dispose();
    _backendUrlFocus.dispose();
    _gatewayUrlFocus.dispose();
    _neteaseCookieFocus.dispose();
    super.dispose();
  }

  void _scrollToTimeline() {
    final ctx = _timelineKey.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _commitBpmInput(CallbookController c, String raw) {
    final parsed = int.tryParse(raw.trim());
    if (parsed != null) {
      c.setBpm(parsed);
    }
    final nextText = '${c.project.meta.bpm}';
    if (_bpmCtrl.text != nextText) {
      _bpmCtrl.text = nextText;
    }
  }

  @override
  Widget build(BuildContext context) {
    _syncMetaControllers();
    final c = widget.controller;
    final scheme = context.colorScheme;
    final bottomInset = BottomInsetScope.of(context);
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(16, 4, 16, 20 + bottomInset),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final twoCols = constraints.maxWidth >= 960;
          final leftColumn = _buildLeftControlColumn(context, c, scheme);
          final timeline = KeyedSubtree(
            key: _timelineKey,
            child: TimelineEditorWidget(controller: c, compact: true),
          );
          if (twoCols) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 4, child: leftColumn),
                const SizedBox(width: 16),
                Expanded(flex: 8, child: timeline),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              leftColumn,
              const SizedBox(height: 12),
              timeline,
            ],
          );
        },
      ),
    );
  }

  Widget _buildLeftControlColumn(
    BuildContext context,
    CallbookController c,
    ColorScheme scheme,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeroCard(context, c, scheme),
        const SizedBox(height: 12),
        _buildCreditsAndEditorCard(context, c, scheme),
        const SizedBox(height: 12),
        _buildAudioSettingsCard(context, c, scheme),
        const SizedBox(height: 12),
        _buildBpmSparkCard(context, c, scheme),
        const SizedBox(height: 12),
        _buildCoverageSparkCard(context, c, scheme),
        const SizedBox(height: 12),
        _buildExportJumpCard(context, c, scheme),
        const SizedBox(height: 12),
        AudioSourcePanel(controller: c),
        const SizedBox(height: 12),
        _buildGatewayConfigCard(context, c, scheme),
      ],
    );
  }

  void _syncNetworkControllers() {
    final c = widget.controller;
    if (c.backendUrl != _lastSyncedBackendUrl) {
      _lastSyncedBackendUrl = c.backendUrl;
      if (!_backendUrlFocus.hasFocus && _backendCtrl.text != c.backendUrl) {
        _backendCtrl.text = c.backendUrl;
      }
    }
    if (c.savedGatewayUrl != _lastSyncedGatewayUrl) {
      _lastSyncedGatewayUrl = c.savedGatewayUrl;
      if (!_gatewayUrlFocus.hasFocus &&
          c.savedGatewayUrl.isNotEmpty &&
          _gatewayUrlCtrl.text != c.savedGatewayUrl) {
        _gatewayUrlCtrl.text = c.savedGatewayUrl;
      }
    }
    if (c.savedNeteaseCookie != _lastSyncedCookie) {
      _lastSyncedCookie = c.savedNeteaseCookie;
      if (!_neteaseCookieFocus.hasFocus &&
          c.savedNeteaseCookie.isNotEmpty &&
          _neteaseCookieCtrl.text.isEmpty) {
        _neteaseCookieCtrl.text = c.savedNeteaseCookie;
      }
    }
  }

  Future<void> _pasteCookieFromClipboard() async {
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    final raw = clip?.text?.trim() ?? '';
    if (raw.isEmpty) {
      widget.controller.setStatus('剪贴板为空，请先复制网易云音乐 Cookie');
      return;
    }
    _neteaseCookieCtrl.text = raw;
    widget.controller.setStatus('已粘贴 Cookie，点击下方按钮验证并保存即可生效');
  }

  Widget _buildHeroCard(
    BuildContext context,
    CallbookController c,
    ColorScheme scheme,
  ) {
    final beats = c.project.meta.beatsPerBar;
    final sourceModeLabel = c.project.meta.audioUrl.isNotEmpty
        ? (c.project.meta.platform == 'local' ? '本地音频' : '在线音源')
        : '节拍器演练';
    final offsetMs = c.project.meta.offsetMs;

    return Card(
      inert: true,
      radius: 26,
      padding: const EdgeInsets.all(16),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            right: -24,
            top: -32,
            child: IgnorePointer(
              child: ScallopedHeroWatermark(running: c.isPlaying, size: 150),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListenableBuilder(
                listenable: c.playbackListenable,
                builder: (context, _) => Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            c.siteText('播放状态'),
                            style: AppTextStyle.caption1
                                .of(context, emphasized: true)
                                .copyWith(color: scheme.onSurfaceVariant),
                          ),
                          TonalChip(
                            label: c.isPlaying ? 'Running' : 'Standby',
                            color: c.isPlaying
                                ? scheme.successContainer
                                : scheme.surfaceContainerHigh,
                            foregroundColor: c.isPlaying
                                ? scheme.onSuccessContainer
                                : scheme.onSurfaceVariant,
                          ),
                          TonalChip(
                            label: sourceModeLabel,
                            color: scheme.primaryContainer,
                            foregroundColor: scheme.onPrimaryContainer,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var b = 1; b <= beats; b++) ...[
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 110),
                            width: 9,
                            height: 9,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: c.isPlaying && c.currentBeatInBar == b
                                  ? (b == 1 ? scheme.error : scheme.primary)
                                  : scheme.surfaceContainerHighest,
                            ),
                          ),
                          const SizedBox(width: 4),
                        ],
                        const SizedBox(width: 2),
                        Text(
                          '${c.currentBar}.${c.currentBeatInBar}',
                          style: AppTextStyle.caption1
                              .of(context, emphasized: true)
                              .copyWith(
                                fontFamily: 'GoogleSans',
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                                color: scheme.onSurfaceVariant,
                              ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextField(
                          controller: _titleCtrl,
                          style: AppTextStyle.headline
                              .of(context, emphasized: true)
                              .copyWith(color: scheme.onSurface),
                          decoration: const InputDecoration.collapsed(
                            hintText: '输入当前歌曲名称',
                          ),
                          onChanged: (v) {
                            _lastSyncedTitle = v;
                            c.updateMeta(title: v);
                          },
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 160),
                              child: TextField(
                                controller: _artistCtrl,
                                style: AppTextStyle.caption1
                                    .of(context)
                                    .copyWith(color: scheme.onSurfaceVariant),
                                decoration: const InputDecoration.collapsed(
                                  hintText: '歌手 / 企划',
                                ),
                                onChanged: (v) {
                                  _lastSyncedArtist = v;
                                  c.updateMeta(artist: v);
                                },
                              ),
                            ),
                            TonalChip(
                              label: '切换曲库 / 导入',
                              color: scheme.surfaceContainerHigh,
                              foregroundColor: scheme.primary,
                              onPressed: () =>
                                  showAudioSourceModal(context, c),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  ScallopedOrbButton(
                    running: c.isPlaying,
                    size: 58,
                    onToggle: c.togglePlay,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ListenableBuilder(
                listenable: c.playbackListenable,
                builder: (context, _) {
                  final safeDuration = math.max(1000, c.durationMs).toDouble();
                  final clampedPos = c.currentTimeMs.toDouble().clamp(
                    0.0,
                    safeDuration,
                  );
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Slider(
                        value: clampedPos,
                        min: 0,
                        max: safeDuration,
                        onChanged: (v) => c.seek(v.round()),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            formatMsToClock(c.currentTimeMs),
                            style: AppTextStyle.caption1.of(context).copyWith(
                              fontFamily: 'GoogleSans',
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          Text(
                            formatMsToClock(safeDuration.round()),
                            style: AppTextStyle.caption1.of(context).copyWith(
                              fontFamily: 'GoogleSans',
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 10),
              const Divider(height: 1),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '播放倍速与校准偏移',
                      style: AppTextStyle.caption1
                          .of(context, emphasized: true)
                          .copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                  TonalChip(
                    label:
                        '首拍 ${offsetMs > 0 ? "+" : ""}${offsetMs}ms ${_showOffsetTools ? "▴" : "▾"}',
                    color: scheme.surfaceContainerHigh,
                    foregroundColor: scheme.onSurface,
                    onPressed: () =>
                        setState(() => _showOffsetTools = !_showOffsetTools),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SegmentedControl<double>(
                segments: const [
                  (0.5, '0.5×'),
                  (0.75, '0.75×'),
                  (1.0, '1.0×'),
                  (1.1, '1.1×'),
                  (1.25, '1.25×'),
                ],
                value: c.playbackRate,
                onChanged: c.setPlaybackRate,
              ),
              if (_showOffsetTools) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    for (final delta in const [-100, -20]) ...[
                      Expanded(
                        child: _OffsetChipButton(
                          label: '$delta',
                          color: scheme.surfaceContainerLow,
                          foreground: scheme.onSurface,
                          onTap: () => c.adjustOffset(delta),
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                    Expanded(
                      child: _OffsetChipButton(
                        label: '归零',
                        color: scheme.surfaceContainerLow,
                        foreground: scheme.onSurfaceVariant,
                        onTap: () => c.setOffset(0),
                      ),
                    ),
                    for (final delta in const [20, 100]) ...[
                      const SizedBox(width: 6),
                      Expanded(
                        child: _OffsetChipButton(
                          label: '+$delta',
                          color: scheme.surfaceContainerLow,
                          foreground: scheme.onSurface,
                          onTap: () => c.adjustOffset(delta),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  TonalChip(
                    label:
                        '${c.displayLayers.showRuby ? "✓ " : ""}日语注音 (Furigana)',
                    color: c.displayLayers.showRuby
                        ? scheme.primaryContainer
                        : scheme.surfaceContainerHigh,
                    foregroundColor: c.displayLayers.showRuby
                        ? scheme.onPrimaryContainer
                        : scheme.onSurfaceVariant,
                    onPressed: () => c.updateDisplayLayers(
                      showRuby: !c.displayLayers.showRuby,
                    ),
                  ),
                  TonalChip(
                    label:
                        '${c.displayLayers.showRomaji ? "✓ " : ""}罗马音 (Romaji)',
                    color: c.displayLayers.showRomaji
                        ? scheme.primaryContainer
                        : scheme.surfaceContainerHigh,
                    foregroundColor: c.displayLayers.showRomaji
                        ? scheme.onPrimaryContainer
                        : scheme.onSurfaceVariant,
                    onPressed: () => c.updateDisplayLayers(
                      showRomaji: !c.displayLayers.showRomaji,
                    ),
                  ),
                  TonalChip(
                    label:
                        '${c.displayLayers.showTranslation ? "✓ " : ""}中文翻译',
                    color: c.displayLayers.showTranslation
                        ? scheme.primaryContainer
                        : scheme.surfaceContainerHigh,
                    foregroundColor: c.displayLayers.showTranslation
                        ? scheme.onPrimaryContainer
                        : scheme.onSurfaceVariant,
                    onPressed: () => c.updateDisplayLayers(
                      showTranslation: !c.displayLayers.showTranslation,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMetaInputField(
    BuildContext context,
    ColorScheme scheme, {
    required String label,
    required String hint,
    required TextEditingController controller,
    required FocusNode focusNode,
    required ValueChanged<String> onChanged,
    int maxLines = 1,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: AppTextStyle.caption2
              .of(context, emphasized: true)
              .copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          focusNode: focusNode,
          maxLines: maxLines,
          minLines: maxLines,
          decoration: InputDecoration(hintText: hint),
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _buildCreditsAndEditorCard(
    BuildContext context,
    CallbookController c,
    ColorScheme scheme,
  ) {
    final showTuner = c.project.meta.showTuner;
    return Card(
      inert: true,
      radius: 22,
      padding: const EdgeInsets.all(14),
      child: FilledInputTheme(
        borderRadius: AppRadius.md,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 8,
        ),
        fillColor: scheme.surfaceContainerHigh,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '曲目制作与编者信息',
                    style: AppTextStyle.headline
                        .of(context, emphasized: true)
                        .copyWith(color: scheme.onSurface),
                  ),
                ),
                GestureDetector(
                  onTap: () => c.updateMeta(showTuner: !showTuner),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Checkbox(
                        value: showTuner,
                        onChanged: (v) =>
                            c.updateMeta(showTuner: v ?? false),
                      ),
                      Text(
                        '添加调教',
                        style: AppTextStyle.footnote
                            .of(context, emphasized: true)
                            .copyWith(color: scheme.onSurface),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _buildMetaInputField(
                    context,
                    scheme,
                    label: '作曲',
                    hint: '如：litterzy',
                    controller: _composerCtrl,
                    focusNode: _composerFocus,
                    onChanged: (v) => c.updateMeta(composer: v),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildMetaInputField(
                    context,
                    scheme,
                    label: '作词',
                    hint: '如：冥凰',
                    controller: _lyricistCtrl,
                    focusNode: _lyricistFocus,
                    onChanged: (v) => c.updateMeta(lyricist: v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _buildMetaInputField(
                    context,
                    scheme,
                    label: '演唱',
                    hint: c.project.meta.artist.isNotEmpty
                        ? c.project.meta.artist
                        : '如：初音ミク',
                    controller: _vocalistCtrl,
                    focusNode: _vocalistFocus,
                    onChanged: (v) => c.updateMeta(vocalist: v),
                  ),
                ),
                if (showTuner) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildMetaInputField(
                      context,
                      scheme,
                      label: '调教',
                      hint: '调教师 / 调声',
                      controller: _tunerCtrl,
                      focusNode: _tunerFocus,
                      onChanged: (v) => c.updateMeta(tuner: v),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            const Divider(height: 1),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _buildMetaInputField(
                    context,
                    scheme,
                    label: '编者',
                    hint: '编者署名（导出前也可填）',
                    controller: _editorNameCtrl,
                    focusNode: _editorNameFocus,
                    onChanged: (v) => c.updateMeta(editorName: v),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildMetaInputField(
                    context,
                    scheme,
                    label: '编者语',
                    hint: 'Call 本说明 / 寄语（可选）',
                    controller: _editorNoteCtrl,
                    focusNode: _editorNoteFocus,
                    onChanged: (v) => c.updateMeta(editorNote: v),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAudioSettingsCard(
    BuildContext context,
    CallbookController c,
    ColorScheme scheme,
  ) {
    return Card(
      inert: true,
      radius: 22,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: ShapeDecoration(
                  color: scheme.primaryContainer,
                  shape: AppShape.circle,
                ),
                alignment: Alignment.center,
                child: GlyphIcon(
                  CallbookGlyphs.musicNote,
                  size: 16,
                  color: scheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '节拍器音频',
                      style: AppTextStyle.subheadline
                          .of(context, emphasized: true)
                          .copyWith(color: scheme.onSurface),
                    ),
                    Text(
                      c.metronomeEnabled
                          ? '音量 ${(c.metronomeVolume * 100).round()}%'
                          : '已静音',
                      style: AppTextStyle.caption2.of(context).copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                value: c.metronomeEnabled,
                onChanged: c.setMetronomeEnabled,
                semanticLabel: '开启节拍器',
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Slider(
                  value: c.metronomeVolume,
                  min: 0.2,
                  max: 1.5,
                  onChanged: c.metronomeEnabled ? c.setMetronomeVolume : null,
                ),
              ),
              const SizedBox(width: 8),
              TonalChip(
                label: '试听',
                color: scheme.surfaceContainerHigh,
                foregroundColor: scheme.onSurface,
                onPressed: c.testMetronomeClick,
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Divider(height: 1),
          const SizedBox(height: 10),
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: ShapeDecoration(
                  color: scheme.warningContainer,
                  shape: AppShape.circle,
                ),
                alignment: Alignment.center,
                child: GlyphIcon(
                  CallbookGlyphs.play,
                  size: 15,
                  color: scheme.onWarningContainer,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'GT 前置警报音',
                      style: AppTextStyle.subheadline
                          .of(context, emphasized: true)
                          .copyWith(color: scheme.onSurface),
                    ),
                    Text(
                      c.gtBeepEnabled ? '进场前自动提示' : '已关闭提示音',
                      style: AppTextStyle.caption2.of(context).copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                value: c.gtBeepEnabled,
                onChanged: c.setGtBeepEnabled,
                semanticLabel: 'GT 警报提示音',
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Divider(height: 1),
          const SizedBox(height: 10),
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: ShapeDecoration(
                  color: scheme.surfaceContainerHigh,
                  shape: AppShape.circle,
                ),
                alignment: Alignment.center,
                child: GlyphIcon(
                  CallbookGlyphs.studio,
                  size: 15,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '歌词时间轴跟随',
                      style: AppTextStyle.subheadline
                          .of(context, emphasized: true)
                          .copyWith(color: scheme.onSurface),
                    ),
                    Text(
                      c.followPlayback ? '自动居中高亮句' : '手动自由滚动',
                      style: AppTextStyle.caption2.of(context).copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                value: c.followPlayback,
                onChanged: c.setFollowPlayback,
                semanticLabel: '歌词时间轴跟随',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBpmSparkCard(
    BuildContext context,
    CallbookController c,
    ColorScheme scheme,
  ) {
    return Card(
      inert: true,
      radius: 22,
      padding: EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: AppRadius.xl,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '节拍速率 (BPM)',
                          style: AppTextStyle.caption1
                              .of(context, emphasized: true)
                              .copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                      TonalChip(
                        label: 'Tap',
                        color: scheme.surfaceContainerHigh,
                        foregroundColor: scheme.onSurface,
                        onPressed: c.tapTempo,
                      ),
                      const SizedBox(width: 6),
                      TonalChip(
                        label: c.project.meta.timeSignature,
                        color: scheme.surfaceContainerHigh,
                        foregroundColor: scheme.onSurface,
                        onPressed: () => c.setTimeSignature(
                          c.project.meta.timeSignature == '4/4'
                              ? '3/4'
                              : '4/4',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      SizedBox(
                        width: 72,
                        child: TextField(
                          controller: _bpmCtrl,
                          focusNode: _bpmFocus,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          decoration: const InputDecoration.collapsed(
                            hintText: '120',
                          ),
                          style: AppTextStyle.title1
                              .of(context, emphasized: true)
                              .copyWith(
                                fontFamily: 'GoogleSans',
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                                color: scheme.onSurface,
                              ),
                          onChanged: (v) {
                            final parsed = int.tryParse(v.trim());
                            if (parsed != null &&
                                parsed >= 30 &&
                                parsed <= 300) {
                              c.setBpm(parsed);
                            }
                          },
                          onSubmitted: (v) => _commitBpmInput(c, v),
                          onEditingComplete: () =>
                              _commitBpmInput(c, _bpmCtrl.text),
                        ),
                      ),
                      Text(
                        'BPM',
                        style: AppTextStyle.caption1
                            .of(context, emphasized: true)
                            .copyWith(color: scheme.onSurfaceVariant),
                      ),
                      const Spacer(),
                      TonalChip(
                        label: '−',
                        color: scheme.surfaceContainerHigh,
                        foregroundColor: scheme.onSurface,
                        onPressed: () => c.setBpm(c.project.meta.bpm - 1),
                      ),
                      const SizedBox(width: 6),
                      TonalChip(
                        label: '+',
                        color: scheme.surfaceContainerHigh,
                        foregroundColor: scheme.onSurface,
                        onPressed: () => c.setBpm(c.project.meta.bpm + 1),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            ListenableBuilder(
              listenable: c.beatListenable,
              builder: (context, _) => SparklineMetricFooter(
                values: c.beatPulseSeries,
                revision: c.beatSeriesRevision,
                color: scheme.primary,
                height: 36,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCoverageSparkCard(
    BuildContext context,
    CallbookController c,
    ColorScheme scheme,
  ) {
    return Card(
      inert: true,
      radius: 22,
      padding: EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: AppRadius.xl,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          c.siteText('编写覆盖率'),
                          style: AppTextStyle.caption1
                              .of(context, emphasized: true)
                              .copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                      TonalChip(
                        label: '+ GT 警报',
                        color: scheme.warningContainer,
                        foregroundColor: scheme.onWarningContainer,
                        onPressed: () => c.insertGtAlert(),
                      ),
                      const SizedBox(width: 6),
                      TonalChip(
                        label: '定位时间轴',
                        color: scheme.surfaceContainerHigh,
                        foregroundColor: scheme.onSurface,
                        onPressed: _scrollToTimeline,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        '${c.taggedLineCount}',
                        style: AppTextStyle.title1
                            .of(context, emphasized: true)
                            .copyWith(
                              fontFamily: 'GoogleSans',
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                              color: scheme.onSurface,
                            ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '/ ${c.sortedLines.length} 句已标 Call · ${c.sortedAlerts.length} GT 警报',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyle.caption1.of(context).copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            SparklineMetricFooter(
              values: c.callDensitySeries,
              revision: c.callDensityRevision,
              color: scheme.tertiary,
              height: 36,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExportJumpCard(
    BuildContext context,
    CallbookController c,
    ColorScheme scheme,
  ) {
    return GestureDetector(
      onTap: () => c.setRoute(StudioRoute.export),
      child: ElasticPress(
        child: Card(
          inert: true,
          radius: 22,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: ShapeDecoration(
                  color: scheme.successContainer,
                  shape: AppShape.circle,
                ),
                alignment: Alignment.center,
                child: GlyphIcon(
                  CallbookGlyphs.exportCard,
                  size: 16,
                  color: scheme.onSuccessContainer,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      c.siteText('导出Callbook'),
                      style: AppTextStyle.subheadline
                          .of(context, emphasized: true)
                          .copyWith(color: scheme.onSurface),
                    ),
                    Text(
                      'PNG 长图 · Excel · Markdown · JSON',
                      style: AppTextStyle.caption2.of(context).copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              GlyphIcon(
                Glyphs.chevronForward,
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGatewayConfigCard(
    BuildContext context,
    CallbookController c,
    ColorScheme scheme,
  ) {
    final gw = c.gatewayStatus;
    final isDesktop = c.isDesktopHost;
    final account = gw.neteaseAccount?.trim() ?? '';
    final backendNodeGatewayActive =
        c.backendOnline &&
        (gw.managedByBackend || (gw.gatewayOnline && gw.nodeAvailable));

    return Card(
      inert: true,
      radius: 22,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            onTap: () => setState(() => _showGatewayCard = !_showGatewayCard),
            behavior: HitTestBehavior.opaque,
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '网易云直连 & 可选后端服务',
                        style: AppTextStyle.subheadline
                            .of(context, emphasized: true)
                            .copyWith(color: scheme.onSurface),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        c.backendOnline
                            ? '后端注音在线 · 支持纯 Dart 直连'
                            : '纯 Dart 引擎直连就绪（点击展开配置）',
                        style: AppTextStyle.caption2.of(context).copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                TonalChip(
                  label: _showGatewayCard ? '收起' : '配置',
                  color: scheme.surfaceContainerHigh,
                  foregroundColor: scheme.onSurface,
                  onPressed: () =>
                      setState(() => _showGatewayCard = !_showGatewayCard),
                ),
              ],
            ),
          ),
          if (_showGatewayCard) ...[
            const SizedBox(height: 10),
            Text(
              c.backendOnline
                  ? '已连接 FastAPI 后端（日语假名/罗马音注音可用）；未开 Node 网关时自动使用内置纯 Dart 引擎直连'
                  : '免 Node / 免后端：App 内置纯 Dart EAPI 引擎直接检索网易云与 LRCLIB；粘贴 MUSIC_U 可登录账号，可选连接 FastAPI 获取假名注音',
              style: AppTextStyle.caption1.of(context).copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                TonalChip(
                  label: '纯 Dart 直连',
                  color: scheme.primaryContainer,
                  foregroundColor: scheme.onPrimaryContainer,
                ),
                TonalChip(
                  label: c.backendOnline ? '后端注音在线' : '后端未连 (可选)',
                  color: c.backendOnline
                      ? scheme.successContainer
                      : scheme.surfaceContainerHigh,
                  foregroundColor: c.backendOnline
                      ? scheme.onSuccessContainer
                      : scheme.onSurfaceVariant,
                ),
                if (backendNodeGatewayActive)
                  TonalChip(
                    label: 'Node 网关运行中',
                    color: scheme.successContainer,
                    foregroundColor: scheme.onSuccessContainer,
                  ),
                if (account.isNotEmpty)
                  TonalChip(
                    label: '已登录: $account',
                    color: scheme.successContainer,
                    foregroundColor: scheme.onSuccessContainer,
                  )
                else if (gw.cookieConfigured)
                  TonalChip(
                    label: '已存 Cookie',
                    color: scheme.secondaryContainer,
                    foregroundColor: scheme.onSecondaryContainer,
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _backendCtrl,
                    focusNode: _backendUrlFocus,
                    decoration: const InputDecoration(
                      hintText:
                          '可选 FastAPI 地址：桌面 127.0.0.1:8000 / 模拟器 10.0.2.2:8000',
                    ),
                    onSubmitted: (v) => c.setBackendUrl(v),
                  ),
                ),
                const SizedBox(width: 8),
                TonalButton(
                  size: TonalButtonSize.compact,
                  label: '连接',
                  onPressed: () => c.setBackendUrl(_backendCtrl.text),
                ),
                if (isDesktop && !c.backendOnline) ...[
                  const SizedBox(width: 8),
                  TonalButton(
                    size: TonalButtonSize.compact,
                    label: c.isLaunchingBackend ? '启动中' : '启动后端',
                    onPressed: c.isLaunchingBackend
                        ? null
                        : c.launchLocalBackendOnDesktop,
                  ),
                ],
              ],
            ),
            if (c.backendOnline) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _gatewayUrlCtrl,
                focusNode: _gatewayUrlFocus,
                decoration: const InputDecoration(
                  hintText: '可选后端网关地址（默认 http://127.0.0.1:3000）',
                ),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '网易云 Cookie（可选：支持完整 Cookie 或 MUSIC_U）',
                    style: AppTextStyle.caption1
                        .of(context, emphasized: true)
                        .copyWith(color: scheme.onSurface),
                  ),
                ),
                if (gw.cookieConfigured && gw.cookieMasked.isNotEmpty)
                  Text(
                    '已存: ${gw.cookieMasked}',
                    style: AppTextStyle.caption1.of(context).copyWith(
                      color: scheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _neteaseCookieCtrl,
              focusNode: _neteaseCookieFocus,
              obscureText: _obscureCookie,
              maxLines: _obscureCookie ? 1 : 3,
              minLines: 1,
              decoration: const InputDecoration(
                hintText: '粘贴 MUSIC_U=... 完整 Cookie 或纯 MUSIC_U 字符串（留空即游客直连）',
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                TonalButton(
                  size: TonalButtonSize.compact,
                  label: '粘贴 Cookie',
                  onPressed: _pasteCookieFromClipboard,
                ),
                TonalButton(
                  size: TonalButtonSize.compact,
                  label: _obscureCookie ? '显示明文' : '隐藏 Cookie',
                  onPressed: () =>
                      setState(() => _obscureCookie = !_obscureCookie),
                ),
                TonalButton(
                  size: TonalButtonSize.compact,
                  label: '清空输入',
                  onPressed: () => setState(() => _neteaseCookieCtrl.clear()),
                ),
                TonalButton(
                  size: TonalButtonSize.compact,
                  label: '检测直连状态',
                  onPressed: () => c.refreshGatewayStatus(probeDirect: true),
                ),
                if (c.backendOnline && gw.managedByBackend)
                  TonalButton(
                    size: TonalButtonSize.compact,
                    label: '停止网关',
                    onPressed:
                        c.isConfiguringGateway ? null : c.stopManagedGateway,
                  ),
              ],
            ),
            const SizedBox(height: 10),
            FilledButton(
              onPressed: c.isConfiguringGateway
                  ? null
                  : () async {
                      await c.oneClickConfigureAndStartGateway(
                        cookie: _neteaseCookieCtrl.text,
                        gatewayUrl: _gatewayUrlCtrl.text,
                      );
                    },
              child: Text(
                c.isConfiguringGateway
                    ? '正在验证与配置...'
                    : (c.backendOnline &&
                              gw.nodeAvailable &&
                              gw.packageAvailable
                          ? '一键写入 Cookie 并启动网关'
                          : '验证并保存 Cookie（纯 Dart 直连）'),
              ),
            ),
            if (gw.message.isNotEmpty || gw.pid != null) ...[
              const SizedBox(height: 8),
              Text(
                '${gw.message}${gw.pid != null ? ' (PID ${gw.pid})' : ''}',
                style: AppTextStyle.caption1.of(context).copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            if (c.backendOnline &&
                !gw.gatewayOnline &&
                (!gw.nodeAvailable || !gw.packageAvailable)) ...[
              const SizedBox(height: 4),
              Text(
                '提示：FastAPI 后端未配置 Node 网关，App 将直接使用内置纯 Dart 引擎直连网易云（同时保留后端注音增强）。',
                style: AppTextStyle.caption1.of(context).copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _OffsetChipButton extends StatelessWidget {
  const _OffsetChipButton({
    required this.label,
    required this.color,
    required this.foreground,
    required this.onTap,
  });

  final String label;
  final Color color;
  final Color foreground;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: ShapeDecoration(
          color: color,
          shape: AppShape.md,
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: AppTextStyle.caption1
              .of(context, emphasized: true)
              .copyWith(
                fontFamily: 'GoogleSans',
                fontFeatures: const [FontFeature.tabularFigures()],
                color: foreground,
              ),
        ),
      ),
    );
  }
}
