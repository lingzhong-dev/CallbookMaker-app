import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:prism_ui/icons/icons.dart';
import 'package:prism_ui/prism_ui.dart';

import '../state/callbook_controller.dart';
import '../utils/lrc_ruby_parser.dart';
import 'theme/app_motion.dart';
import 'theme/app_tokens.dart';
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

  final FocusNode _titleFocus = FocusNode();
  final FocusNode _artistFocus = FocusNode();
  final FocusNode _bpmFocus = FocusNode();
  final FocusNode _composerFocus = FocusNode();
  final FocusNode _lyricistFocus = FocusNode();
  final FocusNode _vocalistFocus = FocusNode();
  final FocusNode _tunerFocus = FocusNode();
  final FocusNode _editorNameFocus = FocusNode();
  final FocusNode _editorNoteFocus = FocusNode();

  bool _showOffsetTools = false;

  @override
  void initState() {
    super.initState();
    final meta = widget.controller.project.meta;
    _titleCtrl = TextEditingController(text: meta.title);
    _artistCtrl = TextEditingController(text: meta.artist);
    _bpmCtrl = TextEditingController(text: '${meta.bpm}');
    _composerCtrl = TextEditingController(text: meta.composer);
    _lyricistCtrl = TextEditingController(text: meta.lyricist);
    _vocalistCtrl = TextEditingController(text: meta.vocalist);
    _tunerCtrl = TextEditingController(text: meta.tuner);
    _editorNameCtrl = TextEditingController(text: meta.editorName);
    _editorNoteCtrl = TextEditingController(text: meta.editorNote);
    _titleFocus.addListener(_onTitleFocusChanged);
    _artistFocus.addListener(_onArtistFocusChanged);
    _bpmFocus.addListener(_onBpmFocusChanged);
    _composerFocus.addListener(_onComposerFocusChanged);
    _lyricistFocus.addListener(_onLyricistFocusChanged);
    _vocalistFocus.addListener(_onVocalistFocusChanged);
    _tunerFocus.addListener(_onTunerFocusChanged);
    _editorNameFocus.addListener(_onEditorNameFocusChanged);
    _editorNoteFocus.addListener(_onEditorNoteFocusChanged);
    widget.controller.projectListenable.addListener(_syncMetaControllers);
  }

  void _commitTitle() {
    final next = _titleCtrl.text;
    if (next != widget.controller.project.meta.title) {
      widget.controller.updateMeta(title: next);
    }
  }

  void _commitArtist() {
    final next = _artistCtrl.text;
    if (next != widget.controller.project.meta.artist) {
      widget.controller.updateMeta(artist: next);
    }
  }

  void _commitComposer() {
    final next = _composerCtrl.text;
    if (next != widget.controller.project.meta.composer) {
      widget.controller.updateMeta(composer: next);
    }
  }

  void _commitLyricist() {
    final next = _lyricistCtrl.text;
    if (next != widget.controller.project.meta.lyricist) {
      widget.controller.updateMeta(lyricist: next);
    }
  }

  void _commitVocalist() {
    final next = _vocalistCtrl.text;
    if (next != widget.controller.project.meta.vocalist) {
      widget.controller.updateMeta(vocalist: next);
    }
  }

  void _commitTuner() {
    final next = _tunerCtrl.text;
    if (next != widget.controller.project.meta.tuner) {
      widget.controller.updateMeta(tuner: next);
    }
  }

  void _commitEditorName() {
    final next = _editorNameCtrl.text;
    if (next != widget.controller.project.meta.editorName) {
      widget.controller.updateMeta(editorName: next);
    }
  }

  void _commitEditorNote() {
    final next = _editorNoteCtrl.text;
    if (next != widget.controller.project.meta.editorNote) {
      widget.controller.updateMeta(editorNote: next);
    }
  }

  void _onTitleFocusChanged() {
    if (!_titleFocus.hasFocus && mounted) _commitTitle();
  }

  void _onArtistFocusChanged() {
    if (!_artistFocus.hasFocus && mounted) _commitArtist();
  }

  void _onBpmFocusChanged() {
    if (!_bpmFocus.hasFocus && mounted) {
      _commitBpmInput(widget.controller, _bpmCtrl.text);
    }
  }

  void _onComposerFocusChanged() {
    if (!_composerFocus.hasFocus && mounted) _commitComposer();
  }

  void _onLyricistFocusChanged() {
    if (!_lyricistFocus.hasFocus && mounted) _commitLyricist();
  }

  void _onVocalistFocusChanged() {
    if (!_vocalistFocus.hasFocus && mounted) _commitVocalist();
  }

  void _onTunerFocusChanged() {
    if (!_tunerFocus.hasFocus && mounted) _commitTuner();
  }

  void _onEditorNameFocusChanged() {
    if (!_editorNameFocus.hasFocus && mounted) _commitEditorName();
  }

  void _onEditorNoteFocusChanged() {
    if (!_editorNoteFocus.hasFocus && mounted) _commitEditorNote();
  }

  @override
  void didUpdateWidget(covariant DashboardView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.projectListenable.removeListener(_syncMetaControllers);
      widget.controller.projectListenable.addListener(_syncMetaControllers);
      _syncMetaControllers();
    }
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
    if (!mounted) return;
    final meta = widget.controller.project.meta;
    _syncFieldIfIdle(_titleCtrl, _titleFocus, meta.title);
    _syncFieldIfIdle(_artistCtrl, _artistFocus, meta.artist);
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
    widget.controller.projectListenable.removeListener(_syncMetaControllers);
    _titleFocus.removeListener(_onTitleFocusChanged);
    _artistFocus.removeListener(_onArtistFocusChanged);
    _bpmFocus.removeListener(_onBpmFocusChanged);
    _composerFocus.removeListener(_onComposerFocusChanged);
    _lyricistFocus.removeListener(_onLyricistFocusChanged);
    _vocalistFocus.removeListener(_onVocalistFocusChanged);
    _tunerFocus.removeListener(_onTunerFocusChanged);
    _editorNameFocus.removeListener(_onEditorNameFocusChanged);
    _editorNoteFocus.removeListener(_onEditorNoteFocusChanged);
    _titleCtrl.dispose();
    _artistCtrl.dispose();
    _bpmCtrl.dispose();
    _composerCtrl.dispose();
    _lyricistCtrl.dispose();
    _vocalistCtrl.dispose();
    _tunerCtrl.dispose();
    _editorNameCtrl.dispose();
    _editorNoteCtrl.dispose();
    _titleFocus.dispose();
    _artistFocus.dispose();
    _bpmFocus.dispose();
    _composerFocus.dispose();
    _lyricistFocus.dispose();
    _vocalistFocus.dispose();
    _tunerFocus.dispose();
    _editorNameFocus.dispose();
    _editorNoteFocus.dispose();
    super.dispose();
  }

  void _scrollToTimeline() {
    final ctx = _timelineKey.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: AppMotion.d(context, AppMotion.effectsSlow),
        curve: AppMotion.curveEffects,
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
            children: [leftColumn, const SizedBox(height: 12), timeline],
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
      ],
    );
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
      radius: AppTokens.radiusCard,
      padding: const EdgeInsets.all(AppTokens.s16),
      child: Column(
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
                        duration: AppMotion.d(context, AppMotion.effectsFast),
                        curve: AppMotion.curveEffects,
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
                            fontFeatures: const [FontFeature.tabularFigures()],
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
                      focusNode: _titleFocus,
                      style: AppTextStyle.headline
                          .of(context, emphasized: true)
                          .copyWith(color: scheme.onSurface),
                      decoration: const InputDecoration.collapsed(
                        hintText: '输入当前歌曲名称',
                      ),
                      onSubmitted: (_) => _commitTitle(),
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
                            focusNode: _artistFocus,
                            style: AppTextStyle.caption1
                                .of(context)
                                .copyWith(color: scheme.onSurfaceVariant),
                            decoration: const InputDecoration.collapsed(
                              hintText: '歌手 / 企划',
                            ),
                            onSubmitted: (_) => _commitArtist(),
                          ),
                        ),
                        TonalChip(
                          label: '切换曲库 / 导入',
                          color: scheme.surfaceContainerHigh,
                          foregroundColor: scheme.primary,
                          onPressed: () => showAudioSourceModal(context, c),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              ListenableBuilder(
                listenable: c.playbackListenable,
                builder: (context, _) => ScallopedOrbButton(
                  running: c.isPlaying,
                  size: 58,
                  onToggle: c.togglePlay,
                ),
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
                        style: AppTextStyle.caption1
                            .of(context)
                            .copyWith(
                              fontFamily: 'GoogleSans',
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                      Text(
                        formatMsToClock(safeDuration.round()),
                        style: AppTextStyle.caption1
                            .of(context)
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
          ListenableBuilder(
            listenable: c.playbackListenable,
            builder: (context, _) => SegmentedControl<double>(
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
                label: '${c.displayLayers.showRuby ? "✓ " : ""}日语注音 (Furigana)',
                color: c.displayLayers.showRuby
                    ? scheme.primaryContainer
                    : scheme.surfaceContainerHigh,
                foregroundColor: c.displayLayers.showRuby
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant,
                onPressed: () =>
                    c.updateDisplayLayers(showRuby: !c.displayLayers.showRuby),
              ),
              TonalChip(
                label: '${c.displayLayers.showRomaji ? "✓ " : ""}罗马音 (Romaji)',
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
                label: '${c.displayLayers.showTranslation ? "✓ " : ""}中文翻译',
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
    );
  }

  Widget _buildMetaInputField(
    BuildContext context,
    ColorScheme scheme, {
    required String label,
    required String hint,
    required TextEditingController controller,
    required FocusNode focusNode,
    required VoidCallback onSubmitted,
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
          onSubmitted: (_) => onSubmitted(),
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
      radius: AppTokens.radiusCard,
      padding: const EdgeInsets.all(14),
      child: FilledInputTheme(
        borderRadius: AppRadius.md,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
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
                        onChanged: (v) => c.updateMeta(showTuner: v ?? false),
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
                    onSubmitted: _commitComposer,
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
                    onSubmitted: _commitLyricist,
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
                    onSubmitted: _commitVocalist,
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
                      onSubmitted: _commitTuner,
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
                    onSubmitted: _commitEditorName,
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
                    onSubmitted: _commitEditorNote,
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
      radius: AppTokens.radiusCard,
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
                      style: AppTextStyle.caption2
                          .of(context)
                          .copyWith(color: scheme.onSurfaceVariant),
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
                      style: AppTextStyle.caption2
                          .of(context)
                          .copyWith(color: scheme.onSurfaceVariant),
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
      radius: AppTokens.radiusCard,
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
                          c.project.meta.timeSignature == '4/4' ? '3/4' : '4/4',
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
      radius: AppTokens.radiusCard,
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
                          style: AppTextStyle.caption1
                              .of(context)
                              .copyWith(color: scheme.onSurfaceVariant),
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
          radius: AppTokens.radiusCard,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: AppTokens.s12),
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
                      style: AppTextStyle.caption2
                          .of(context)
                          .copyWith(color: scheme.onSurfaceVariant),
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
        decoration: ShapeDecoration(color: color, shape: AppShape.md),
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
