import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:prism_ui/icons/icons.dart';
import 'package:prism_ui/prism_ui.dart';

import '../data/default_songs.dart';
import '../state/callbook_controller.dart';
import '../utils/color_parser.dart';
import 'theme/app_motion.dart';
import 'widgets/archive_switcher_dialog.dart';
import 'widgets/callbook_glyphs.dart';

class OnboardingOverlay extends StatefulWidget {
  const OnboardingOverlay({super.key, required this.controller});

  final CallbookController controller;

  @override
  State<OnboardingOverlay> createState() => _OnboardingOverlayState();
}

class _OnboardingOverlayState extends State<OnboardingOverlay> {
  static const int _totalSteps = 5;

  int _step = 0;
  late String _selectedSongId;
  bool _userPickedSong = false;
  bool _customColorExpanded = false;
  final TextEditingController _colorCtrl = TextEditingController();
  Timer? _colorDebounceTimer;
  Color? _parsedCustomColor;
  String? _colorError;

  @override
  void initState() {
    super.initState();
    _selectedSongId =
        findDefaultSongByProject(widget.controller.project)?.id ??
        defaultPrimarySong.id;
    _colorCtrl.text = formatHexColor(widget.controller.seedColor);
  }

  @override
  void dispose() {
    _colorDebounceTimer?.cancel();
    _colorCtrl.dispose();
    super.dispose();
  }

  void _onColorInputChanged(String raw) {
    _colorDebounceTimer?.cancel();
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _parsedCustomColor = null;
        _colorError = null;
      });
      return;
    }
    final parsed = parseSupportColor(trimmed);
    if (parsed == null) {
      setState(() {
        _parsedCustomColor = null;
        _colorError = '格式无效：支持 #RRGGBB、#RGB 或 RGB (如 102, 204, 255)';
      });
      return;
    }
    setState(() {
      _parsedCustomColor = parsed;
      _colorError = null;
    });
    _colorDebounceTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      widget.controller.setSeedColor(parsed);
    });
  }

  void _applyColorInput() {
    _colorDebounceTimer?.cancel();
    final parsed = parseSupportColor(_colorCtrl.text);
    if (parsed == null) {
      setState(() {
        _parsedCustomColor = null;
        _colorError = '格式无效：支持 #RRGGBB、#RGB 或 RGB (如 102, 204, 255)';
      });
      return;
    }
    setState(() {
      _parsedCustomColor = parsed;
      _colorError = null;
    });
    widget.controller.setSeedColor(parsed);
  }

  Future<void> _handleStartCreating() async {
    final c = widget.controller;
    final currentSpec = findDefaultSongByProject(c.project);
    final selectedSpec =
        findDefaultSongById(_selectedSongId) ?? defaultPrimarySong;
    if (c.onboardingReopened &&
        _userPickedSong &&
        currentSpec?.id != selectedSpec.id &&
        c.needsSavePromptBeforeSwitch) {
      final ok = await confirmArchiveSaveIfNeeded(
        context,
        c,
        actionLabel: '切换默认曲目',
        targetLabel: selectedSpec.project.meta.title,
      );
      if (!ok || !mounted) return;
    }
    await c.completeOnboarding(
      selectedSongId: _selectedSongId,
      userExplicitlyPickedSong: _userPickedSong,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final scheme = context.colorScheme;
    final isDark = scheme.brightness == Brightness.dark;

    return Positioned.fill(
      child: Surface(
        color: isDark ? const Color(0xCC000000) : const Color(0x990F172A),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, viewport) {
              final isMobile = viewport.maxWidth < 720;
              final maxModalHeight = (viewport.maxHeight - (isMobile ? 24 : 48))
                  .clamp(280.0, 820.0);

              return Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: isMobile ? 12 : 24,
                    vertical: isMobile ? 12 : 24,
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: isMobile ? 540 : 760,
                      maxHeight: maxModalHeight,
                    ),
                    child: DecoratedBox(
                      decoration: ShapeDecoration(
                        color: scheme.surfaceContainerLowest,
                        shape: RoundedSuperellipseBorder(
                          borderRadius: AppRadius.xl,
                          side: BorderSide(color: scheme.outlineVariant),
                        ),
                        shadows: [
                          BoxShadow(
                            color: scheme.shadow.withValues(
                              alpha: isDark ? 0.48 : 0.18,
                            ),
                            blurRadius: 32,
                            offset: const Offset(0, 12),
                          ),
                        ],
                      ),
                      child: SurfaceScope(
                        level: SurfaceLevel.card,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildHeader(context, c, scheme, isMobile),
                            Container(height: 1, color: scheme.outlineVariant),
                            Flexible(
                              child: SingleChildScrollView(
                                padding: EdgeInsets.all(isMobile ? 16 : 24),
                                child: _buildStepBody(
                                  context,
                                  c,
                                  scheme,
                                  isMobile,
                                ),
                              ),
                            ),
                            Container(height: 1, color: scheme.outlineVariant),
                            _buildFooter(context, c, scheme, isMobile),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    CallbookController c,
    ColorScheme scheme,
    bool isMobile,
  ) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        isMobile ? 16 : 24,
        isMobile ? 12 : 16,
        isMobile ? 12 : 20,
        isMobile ? 12 : 14,
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: ShapeDecoration(
              color: scheme.primaryContainer,
              shape: AppShape.full,
            ),
            child: Text(
              '功能引导 · ${_step + 1} / $_totalSteps',
              style: AppTextStyle.caption1
                  .of(context, emphasized: true)
                  .copyWith(color: scheme.onPrimaryContainer),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.center,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < _totalSteps; i++)
                    GestureDetector(
                      onTap: () => setState(() => _step = i),
                      behavior: HitTestBehavior.opaque,
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: isMobile ? 2 : 3,
                          vertical: 6,
                        ),
                        child: AnimatedContainer(
                          duration: AppMotion.d(
                            context,
                            AppMotion.effectsDefault,
                          ),
                          curve: AppMotion.curveEffects,
                          width: i == _step
                              ? (isMobile ? 18 : 22)
                              : (isMobile ? 6 : 8),
                          height: 8,
                          decoration: ShapeDecoration(
                            color: i == _step
                                ? scheme.primary
                                : (i < _step
                                      ? scheme.primary.withValues(alpha: 0.45)
                                      : scheme.outlineVariant),
                            shape: AppShape.full,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          TextButton(
            onPressed: c.skipOnboarding,
            child: const Text('跳过引导'),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter(
    BuildContext context,
    CallbookController c,
    ColorScheme scheme,
    bool isMobile,
  ) {
    final isLast = _step == _totalSteps - 1;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        isMobile ? 16 : 24,
        isMobile ? 12 : 14,
        isMobile ? 16 : 24,
        isMobile ? 12 : 16,
      ),
      child: Row(
        children: [
          if (_step > 0)
            OutlinedButton.icon(
              onPressed: () => setState(() => _step--),
              icon: const GlyphIcon(Glyphs.chevronBack, size: 16),
              label: const Text('上一步'),
            )
          else
            const SizedBox.shrink(),
          const Spacer(),
          if (!isLast)
            FilledButton.icon(
              onPressed: () => setState(() => _step++),
              icon: const GlyphIcon(Glyphs.chevronForward, size: 16),
              label: const Text('下一步'),
            )
          else
            FilledButton.icon(
              onPressed: _handleStartCreating,
              icon: const GlyphIcon(Glyphs.check, size: 16),
              label: const Text('开始创作'),
            ),
        ],
      ),
    );
  }

  Widget _buildStepBody(
    BuildContext context,
    CallbookController c,
    ColorScheme scheme,
    bool isMobile,
  ) {
    return switch (_step) {
      0 => _buildStepWelcome(context, scheme, isMobile),
      1 => _buildStepImport(context, scheme, isMobile),
      2 => _buildStepCallAlign(context, scheme, isMobile),
      3 => _buildStepPracticeExport(context, scheme, isMobile),
      _ => _buildStepThemeAndSong(context, c, scheme, isMobile),
    };
  }

  Widget _buildStepIntroHeader(
    BuildContext context,
    ColorScheme scheme, {
    required Glyph glyph,
    required String title,
    required String subtitle,
    required List<String> tags,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: ShapeDecoration(
                color: scheme.primaryContainer,
                shape: AppShape.lg,
              ),
              alignment: Alignment.center,
              child: GlyphIcon(glyph, size: 22, color: scheme.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AppTextStyle.title2
                        .of(context, emphasized: true)
                        .copyWith(color: scheme.onSurface),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    subtitle,
                    style: AppTextStyle.body.of(context).copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final tag in tags)
              TonalChip(
                label: tag,
                color: scheme.secondaryContainer,
                foregroundColor: scheme.onSecondaryContainer,
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildStepWelcome(
    BuildContext context,
    ColorScheme scheme,
    bool isMobile,
  ) {
    final highlights = [
      (
        glyph: CallbookGlyphs.dashboard,
        title: '全曲时间轴',
        desc: '按毫秒与小节精确同步每句歌词与前/间/尾奏区段',
      ),
      (
        glyph: CallbookGlyphs.studio,
        title: '专属 Call 库',
        desc: '内置 10 项常用应援动作并支持自定义口号标签与颜色',
      ),
      (
        glyph: CallbookGlyphs.fullscreen,
        title: '纯黑演练',
        desc: 'OLED 高对比大字提词舞台，跟着节拍倒数实战打 Call',
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildStepIntroHeader(
          context,
          scheme,
          glyph: CallbookGlyphs.musicNote,
          title: '欢迎来到 Callbook Maker · 为你的偶像写下专属 Call 本',
          subtitle: '专为 Live 现场与打 Call 同好打造的创作台',
          tags: const ['全曲时间轴', '专属 Call 库', '纯黑演练'],
        ),
        const SizedBox(height: 18),
        if (isMobile)
          Column(
            children: [
              for (var i = 0; i < highlights.length; i++) ...[
                _FeatureHighlightTile(
                  glyph: highlights[i].glyph,
                  title: highlights[i].title,
                  desc: highlights[i].desc,
                ),
                if (i < highlights.length - 1) const SizedBox(height: 10),
              ],
            ],
          )
        else
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < highlights.length; i++) ...[
                  Expanded(
                    child: _FeatureHighlightTile(
                      glyph: highlights[i].glyph,
                      title: highlights[i].title,
                      desc: highlights[i].desc,
                    ),
                  ),
                  if (i < highlights.length - 1) const SizedBox(width: 10),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildStepImport(
    BuildContext context,
    ColorScheme scheme,
    bool isMobile,
  ) {
    final sections = [
      (
        badge: '前奏 Intro',
        time: '00:00 → 00:12',
        note: '自动识别开场空档',
        color: scheme.primaryContainer,
        fg: scheme.onPrimaryContainer,
      ),
      (
        badge: '主歌 Verse',
        time: '00:12 → 00:26',
        note: '带歌词、假名注音与中文翻译',
        color: scheme.surfaceContainerHigh,
        fg: scheme.onSurface,
      ),
      (
        badge: '间奏 Interlude',
        time: '00:26 → 00:36',
        note: '超阈值空档自动切分间奏段',
        color: scheme.warningContainer,
        fg: scheme.onWarningContainer,
      ),
      (
        badge: '尾奏 Outro',
        time: '03:32 → 03:54',
        note: '曲末留白自动生成尾奏区间',
        color: scheme.tertiaryContainer,
        fg: scheme.onTertiaryContainer,
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildStepIntroHeader(
          context,
          scheme,
          glyph: CallbookGlyphs.archive,
          title: '选歌导入，自动识别间奏分段',
          subtitle: '支持网易云直连、LRCLIB 检索与本地音轨导入，解析歌词后自动切分前奏、间奏与尾奏空档。',
          tags: const ['直连检索', '本地音频 + LRC', '自动划分前/间/尾奏'],
        ),
        const SizedBox(height: 18),
        Container(
          padding: EdgeInsets.all(isMobile ? 12 : 16),
          decoration: ShapeDecoration(
            color: scheme.surfaceContainerLow,
            shape: AppShape.lg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '歌词时间轴分段示意图',
                style: AppTextStyle.caption1
                    .of(context, emphasized: true)
                    .copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 10),
              for (var i = 0; i < sections.length; i++) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 9,
                  ),
                  decoration: ShapeDecoration(
                    color: scheme.surfaceContainerLowest,
                    shape: AppShape.md,
                  ),
                  child: isMobile
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: TonalChip(
                                      label: sections[i].badge,
                                      color: sections[i].color,
                                      foregroundColor: sections[i].fg,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  sections[i].time,
                                  style: AppTextStyle.caption2
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
                            const SizedBox(height: 6),
                            Text(
                              sections[i].note,
                              style: AppTextStyle.caption1.of(context).copyWith(
                                color: scheme.onSurface,
                              ),
                            ),
                          ],
                        )
                      : Row(
                          children: [
                            TonalChip(
                              label: sections[i].badge,
                              color: sections[i].color,
                              foregroundColor: sections[i].fg,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                sections[i].note,
                                style: AppTextStyle.caption1
                                    .of(context)
                                    .copyWith(color: scheme.onSurface),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              sections[i].time,
                              style: AppTextStyle.caption2.of(context).copyWith(
                                fontFamily: 'GoogleSans',
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                ),
                if (i < sections.length - 1) const SizedBox(height: 6),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStepCallAlign(
    BuildContext context,
    ColorScheme scheme,
    bool isMobile,
  ) {
    final shortcuts = [
      ('1', '前挥'),
      ('2', 'Fuwa'),
      ('3', 'PPPH'),
      ('9', '跟唱'),
      ('0', '拍手'),
      ('G', 'GT 警报'),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildStepIntroHeader(
          context,
          scheme,
          glyph: CallbookGlyphs.studio,
          title: 'Call词精准对位',
          subtitle: '内置常用军Call动作库与快捷键，自带Call词一键对位。',
          tags: const ['方便', '快捷', '可随时撤回手滑操作'],
        ),
        const SizedBox(height: 18),
        Container(
          padding: EdgeInsets.all(isMobile ? 12 : 16),
          decoration: ShapeDecoration(
            color: scheme.surfaceContainerLow,
            shape: AppShape.lg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  TonalChip(
                    label: '前挥 ×4',
                    color: scheme.primary,
                    foregroundColor: scheme.onPrimary,
                  ),
                  TonalChip(
                    label: 'PPPH',
                    color: scheme.primaryContainer,
                    foregroundColor: scheme.onPrimaryContainer,
                  ),
                  const TonalChip(
                    label: '尾句上升气流 ↑',
                    color: Color(0xFF0284C7),
                    foregroundColor: Color(0xFFFFFFFF),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                '带我飞去你的身旁 放声地歌唱',
                style: AppTextStyle.headline
                    .of(context, emphasized: true)
                    .copyWith(color: scheme.onSurface),
              ),
              const SizedBox(height: 4),
              Text(
                '在编辑台选中任意字词段落，即可绑定口号（如「はいせーの！」「Fu~ Fuwa!」），并支持 Ctrl+Z / 撤销按钮随时回退。',
                style: AppTextStyle.caption1.of(context).copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (key, label) in shortcuts)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: ShapeDecoration(
                        color: scheme.surfaceContainerHigh,
                        shape: AppShape.full,
                      ),
                      child: Text(
                        '$key · $label',
                        style: AppTextStyle.caption1
                            .of(context, emphasized: true)
                            .copyWith(color: scheme.onSurface),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStepPracticeExport(
    BuildContext context,
    ColorScheme scheme,
    bool isMobile,
  ) {
    final outputs = [
      (
        glyph: CallbookGlyphs.fullscreen,
        title: '大屏跟拍演练（快捷键 F）',
        desc: '纯黑高对比全屏提词，实时节拍器点阵 + GT 警报高亮与备注',
      ),
      (
        glyph: CallbookGlyphs.exportCard,
        title: 'PNG 长图 & Excel (.xlsx)',
        desc: '自动排版日文假名注音、颜色图例与逐句清单，直接发群或打印携带',
      ),
      (
        glyph: CallbookGlyphs.archive,
        title: 'Markdown / JSON 工程备份',
        desc: '导出 JSON 工程文件或复制 Markdown，与同好无缝接力共创',
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildStepIntroHeader(
          context,
          scheme,
          glyph: CallbookGlyphs.exportCard,
          title: '演练模式与一键导出',
          subtitle: '打开演练模式沉浸跟打练习，随时保存为高清长图、表格清单或可分享工程文件带去 Live 现场。',
          tags: const ['大屏跟拍演练', '高清长图出图', '工程备份分享'],
        ),
        const SizedBox(height: 18),
        Column(
          children: [
            for (var i = 0; i < outputs.length; i++) ...[
              _FeatureHighlightTile(
                glyph: outputs[i].glyph,
                title: outputs[i].title,
                desc: outputs[i].desc,
              ),
              if (i < outputs.length - 1) const SizedBox(height: 8),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildStepThemeAndSong(
    BuildContext context,
    CallbookController c,
    ColorScheme scheme,
    bool isMobile,
  ) {
    final activePreviewColor = _parsedCustomColor ?? c.seedColor;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildStepIntroHeader(
          context,
          scheme,
          glyph: CallbookGlyphs.theme,
          title: '选择你喜欢的主题，并选择一首歌曲',
          subtitle: '挑选你喜欢的主题，选择一首曲目来开始你的第一本Call本',
          tags: const ['实时生效', '可随时在外观页切换'],
        ),
        const SizedBox(height: 16),

        // Theme color swatches
        Text(
          '应援主题色',
          style: AppTextStyle.subheadline
              .of(context, emphasized: true)
              .copyWith(color: scheme.onSurface),
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 520;
            final swatchCards = [
              for (final opt in defaultOnboardingThemeColors)
                _buildColorSwatchCard(context, c, scheme, opt),
            ];
            if (compact) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < swatchCards.length; i++) ...[
                    swatchCards[i],
                    if (i < swatchCards.length - 1) const SizedBox(height: 8),
                  ],
                ],
              );
            }
            return Row(
              children: [
                for (var i = 0; i < swatchCards.length; i++) ...[
                  Expanded(child: swatchCards[i]),
                  if (i < swatchCards.length - 1) const SizedBox(width: 8),
                ],
              ],
            );
          },
        ),
        const SizedBox(height: 8),

        // Custom color expandable trigger & input
        Align(
          alignment: Alignment.centerLeft,
          child: TonalChip(
            label: _customColorExpanded ? '收起自定义应援色' : '或是输入其他应援色',
            color: _customColorExpanded
                ? scheme.primaryContainer
                : scheme.surfaceContainerHigh,
            foregroundColor: _customColorExpanded
                ? scheme.onPrimaryContainer
                : scheme.onSurface,
            onPressed: () {
              setState(() {
                _customColorExpanded = !_customColorExpanded;
                if (_customColorExpanded && _colorCtrl.text.trim().isEmpty) {
                  _colorCtrl.text = formatHexColor(c.seedColor);
                }
              });
            },
          ),
        ),
        if (_customColorExpanded) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: ShapeDecoration(
              color: scheme.surfaceContainerLow,
              shape: AppShape.lg,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      margin: const EdgeInsets.only(top: 4),
                      decoration: BoxDecoration(
                        color: activePreviewColor,
                        shape: BoxShape.circle,
                        border: Border.all(color: scheme.outline, width: 1.5),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _colorCtrl,
                        decoration: InputDecoration(
                          hintText: '输入 Hex (#66CCFF) 或 RGB (102, 204, 255)',
                          errorText: _colorError,
                        ),
                        onChanged: _onColorInputChanged,
                        onSubmitted: (_) => _applyColorInput(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: FilledButton(
                        onPressed: _applyColorInput,
                        child: const Text('应用'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '当前生效：${formatHexColor(c.seedColor)} · RGB(${formatRgbColor(c.seedColor)})',
                  style: AppTextStyle.caption2.of(context).copyWith(
                    fontFamily: 'GoogleSans',
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 14),

        // ThemeMode selector
        Text(
          '明暗模式',
          style: AppTextStyle.subheadline
              .of(context, emphasized: true)
              .copyWith(color: scheme.onSurface),
        ),
        const SizedBox(height: 8),
        SegmentedControl<ThemeMode>(
          segments: const [
            (ThemeMode.system, '跟随系统'),
            (ThemeMode.light, '浅色'),
            (ThemeMode.dark, '深色'),
          ],
          value: c.themeMode,
          onChanged: c.setThemeMode,
        ),
        const SizedBox(height: 16),

        // Single-select default song cards
        Text(
          '选择初始曲目（单选）',
          style: AppTextStyle.subheadline
              .of(context, emphasized: true)
              .copyWith(color: scheme.onSurface),
        ),
        const SizedBox(height: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < defaultSongs.length; i++) ...[
              _buildSongChoiceCard(context, scheme, defaultSongs[i]),
              if (i < defaultSongs.length - 1) const SizedBox(height: 8),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildColorSwatchCard(
    BuildContext context,
    CallbookController c,
    ColorScheme scheme,
    OnboardingThemeColorOption opt,
  ) {
    final isSelected = c.seedColor.toARGB32() == opt.color.toARGB32();
    return Card(
      isSelected: isSelected,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      radius: 16,
      shape: RoundedSuperellipseBorder(
        borderRadius: AppRadius.lg,
        side: BorderSide(
          color: isSelected ? scheme.primary : scheme.outlineVariant,
          width: isSelected ? 2 : 1,
        ),
      ),
      onPressed: () {
        setState(() {
          _parsedCustomColor = opt.color;
          _colorError = null;
          _colorCtrl.text = opt.hex;
        });
        c.setSeedColor(opt.color);
      },
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: opt.color,
              shape: BoxShape.circle,
              border: Border.all(
                color: scheme.onSurface.withValues(alpha: 0.2),
                width: 1,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  opt.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyle.subheadline
                      .of(context, emphasized: true)
                      .copyWith(color: scheme.onSurface),
                ),
                Text(
                  opt.hex,
                  style: AppTextStyle.caption2.of(context).copyWith(
                    fontFamily: 'GoogleSans',
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (isSelected)
            GlyphIcon(Glyphs.check, size: 16, color: scheme.primary),
        ],
      ),
    );
  }

  Widget _buildSongChoiceCard(
    BuildContext context,
    ColorScheme scheme,
    DefaultSongSpec spec,
  ) {
    final isSelected = _selectedSongId == spec.id;
    return Card(
      isSelected: isSelected,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      radius: 16,
      shape: RoundedSuperellipseBorder(
        borderRadius: AppRadius.lg,
        side: BorderSide(
          color: isSelected ? scheme.primary : scheme.outlineVariant,
          width: isSelected ? 2 : 1,
        ),
      ),
      onPressed: () {
        setState(() {
          _selectedSongId = spec.id;
          _userPickedSong = true;
        });
      },
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: ShapeDecoration(
              color: isSelected
                  ? scheme.primaryContainer
                  : scheme.surfaceContainerHigh,
              shape: AppShape.md,
            ),
            alignment: Alignment.center,
            child: GlyphIcon(
              CallbookGlyphs.musicNote,
              size: 18,
              color: isSelected ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 12),
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
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: isSelected ? scheme.primary : const Color(0x00000000),
              shape: BoxShape.circle,
              border: Border.all(
                color: isSelected ? scheme.primary : scheme.outline,
                width: 1.5,
              ),
            ),
            alignment: Alignment.center,
            child: isSelected
                ? GlyphIcon(Glyphs.check, size: 14, color: scheme.onPrimary)
                : null,
          ),
        ],
      ),
    );
  }
}

class _FeatureHighlightTile extends StatelessWidget {
  const _FeatureHighlightTile({
    required this.glyph,
    required this.title,
    required this.desc,
  });

  final Glyph glyph;
  final String title;
  final String desc;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: ShapeDecoration(
        color: scheme.surfaceContainerLow,
        shape: AppShape.lg,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: ShapeDecoration(
              color: scheme.primaryContainer,
              shape: AppShape.md,
            ),
            alignment: Alignment.center,
            child: GlyphIcon(glyph, size: 17, color: scheme.primary),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: AppTextStyle.subheadline
                      .of(context, emphasized: true)
                      .copyWith(color: scheme.onSurface),
                ),
                const SizedBox(height: 3),
                Text(
                  desc,
                  style: AppTextStyle.caption1.of(context).copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
