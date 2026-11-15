import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart';

import '../state/callbook_controller.dart';
import '../utils/lrc_ruby_parser.dart';
import 'widgets/archive_switcher_dialog.dart';
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
  late final TextEditingController _titleCtrl;
  late final TextEditingController _artistCtrl;
  late final TextEditingController _composerCtrl;
  late final TextEditingController _lyricistCtrl;
  late final TextEditingController _vocalistCtrl;
  late final TextEditingController _tunerCtrl;
  late final TextEditingController _editorNameCtrl;
  late final TextEditingController _editorNoteCtrl;

  final FocusNode _composerFocus = FocusNode();
  final FocusNode _lyricistFocus = FocusNode();
  final FocusNode _vocalistFocus = FocusNode();
  final FocusNode _tunerFocus = FocusNode();
  final FocusNode _editorNameFocus = FocusNode();
  final FocusNode _editorNoteFocus = FocusNode();

  final TextEditingController _searchCtrl = TextEditingController(
    text: 'Starlight',
  );
  final TextEditingController _lrcCtrl = TextEditingController();
  final TextEditingController _transCtrl = TextEditingController();
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
  String _searchSource = 'auto';
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
    widget.controller.addListener(_syncNetworkControllers);
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
    _syncFieldIfIdle(_composerCtrl, _composerFocus, meta.composer);
    _syncFieldIfIdle(_lyricistCtrl, _lyricistFocus, meta.lyricist);
    _syncFieldIfIdle(_vocalistCtrl, _vocalistFocus, meta.vocalist);
    _syncFieldIfIdle(_tunerCtrl, _tunerFocus, meta.tuner);
    _syncFieldIfIdle(_editorNameCtrl, _editorNameFocus, meta.editorName);
    _syncFieldIfIdle(_editorNoteCtrl, _editorNoteFocus, meta.editorNote);
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _artistCtrl.dispose();
    _composerCtrl.dispose();
    _lyricistCtrl.dispose();
    _vocalistCtrl.dispose();
    _tunerCtrl.dispose();
    _editorNameCtrl.dispose();
    _editorNoteCtrl.dispose();
    _composerFocus.dispose();
    _lyricistFocus.dispose();
    _vocalistFocus.dispose();
    _tunerFocus.dispose();
    _editorNameFocus.dispose();
    _editorNoteFocus.dispose();
    widget.controller.removeListener(_syncNetworkControllers);
    _searchCtrl.dispose();
    _lrcCtrl.dispose();
    _transCtrl.dispose();
    _backendCtrl.dispose();
    _gatewayUrlCtrl.dispose();
    _neteaseCookieCtrl.dispose();
    _backendUrlFocus.dispose();
    _gatewayUrlFocus.dispose();
    _neteaseCookieFocus.dispose();
    super.dispose();
  }

  Future<void> _pickLocalAudio() async {
    final c = widget.controller;
    final res = await FilePicker.platform.pickFiles(
      type: FileType.audio,
      withData: false,
    );
    if (res == null || res.files.isEmpty) return;
    final file = res.files.first;
    final path = file.path;
    if (path != null && path.isNotEmpty) {
      await c.loadLocalAudioFile(path, file.name);
    }
  }

  @override
  Widget build(BuildContext context) {
    _syncMetaControllers();
    final c = widget.controller;
    final scheme = context.colorScheme;
    final bottomInset = BottomInsetScope.of(context);
    final safeDuration = math.max(1000, c.durationMs).toDouble();
    final clampedPos = c.currentTimeMs.toDouble().clamp(0.0, safeDuration);
    final coveragePct = c.project.lines.isEmpty
        ? 0
        : ((c.taggedLineCount / c.project.lines.length) * 100).round();

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(16, 4, 16, 20 + bottomInset),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 900;
              final heroCard = _buildHeroCard(
                context,
                c,
                scheme,
                safeDuration,
                clampedPos,
              );
              final rightGrid = _buildMetricsBento(
                context,
                c,
                scheme,
                coveragePct,
              );
              if (wide) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 5, child: heroCard),
                    const SizedBox(width: 12),
                    Expanded(flex: 7, child: rightGrid),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  heroCard,
                  const SizedBox(height: 12),
                  rightGrid,
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          _buildControlStrip(context, c, scheme),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final twoCols = constraints.maxWidth >= 960;
              final sourceColumn = _buildSourceAndLrcColumn(context, c, scheme);
              final timeline = TimelineEditorWidget(controller: c, compact: true);
              if (twoCols) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 4, child: sourceColumn),
                    const SizedBox(width: 12),
                    Expanded(flex: 7, child: timeline),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  sourceColumn,
                  const SizedBox(height: 12),
                  timeline,
                ],
              );
            },
          ),
        ],
      ),
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
    widget.controller.setStatus('已粘贴 Cookie，点击“一键写入 Cookie 并启动网关”即可生效');
  }

  Widget _buildGatewayConfigCard(
    BuildContext context,
    CallbookController c,
    ColorScheme scheme,
  ) {
    final gw = c.gatewayStatus;
    final isDesktop = c.isDesktopHost;
    final account = gw.neteaseAccount?.trim() ?? '';
    return Card(
      inert: true,
      radius: 22,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '网易云网关 & 曲库服务',
                      style: AppTextStyle.subheadline
                          .of(context, emphasized: true)
                          .copyWith(color: scheme.onSurface),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      isDesktop
                          ? '粘贴网易云 Cookie 后自动写入 .env 并启动本地网关服务'
                          : '连接 PC 端 FastAPI 后，粘贴网易云 Cookie 即可远程启动网关',
                      style: AppTextStyle.caption1.of(context).copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                alignment: WrapAlignment.end,
                children: [
                  TonalChip(
                    label: c.backendOnline ? '后端在线' : '后端离线',
                    color: c.backendOnline
                        ? scheme.successContainer
                        : scheme.warningContainer,
                    foregroundColor: c.backendOnline
                        ? scheme.onSuccessContainer
                        : scheme.onWarningContainer,
                  ),
                  TonalChip(
                    label: gw.gatewayOnline ? '网关运行中' : '网关未启动',
                    color: gw.gatewayOnline
                        ? scheme.successContainer
                        : scheme.warningContainer,
                    foregroundColor: gw.gatewayOnline
                        ? scheme.onSuccessContainer
                        : scheme.onWarningContainer,
                  ),
                  if (account.isNotEmpty)
                    TonalChip(
                      label: '已登录: $account',
                      color: scheme.primaryContainer,
                      foregroundColor: scheme.onPrimaryContainer,
                    ),
                ],
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
                    hintText: 'FastAPI 地址：桌面 http://127.0.0.1:8000 / 模拟器 10.0.2.2:8000',
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
          const SizedBox(height: 8),
          TextField(
            controller: _gatewayUrlCtrl,
            focusNode: _gatewayUrlFocus,
            decoration: const InputDecoration(
              hintText: '网易云网关地址（默认 http://127.0.0.1:3000）',
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  '网易云 Cookie（支持完整浏览器 Cookie 或 MUSIC_U）',
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
              hintText: '粘贴 MUSIC_U=... 完整 Cookie 或纯 MUSIC_U 字符串',
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
                label: '检测状态',
                onPressed: c.refreshGatewayStatus,
              ),
              if (gw.managedByBackend)
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
                    final ok = await c.oneClickConfigureAndStartGateway(
                      cookie: _neteaseCookieCtrl.text,
                      gatewayUrl: _gatewayUrlCtrl.text,
                    );
                    if (ok && mounted) {
                      setState(() => _searchSource = 'custom_proxy');
                    }
                  },
            child: Text(
              c.isConfiguringGateway ? '正在配置并启动网关...' : '一键写入 Cookie 并启动网关',
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
              !gw.nodeAvailable
                  ? '环境提示：后端未检测到 Node.js，请确认已安装 Node.js 并在 PATH 中。'
                  : '环境提示：未找到 @neteasecloudmusicapienhanced/api，可在后台安装或填远程网关地址。',
              style: AppTextStyle.caption1.of(context).copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildHeroCard(
    BuildContext context,
    CallbookController c,
    ColorScheme scheme,
    double safeDuration,
    double clampedPos,
  ) {
    final beats = c.project.meta.beatsPerBar;
    return Card(
      inert: true,
      radius: 26,
      padding: const EdgeInsets.all(18),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            right: -28,
            bottom: -36,
            child: IgnorePointer(
              child: ScallopedHeroWatermark(running: c.isPlaying, size: 172),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 6,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TonalChip(
                    label: c.isPlaying
                        ? 'PLAYING · BAR ${c.currentBar}.${c.currentBeatInBar}'
                        : 'READY · ${c.project.meta.platform.toUpperCase()}',
                    color: c.isPlaying
                        ? scheme.primaryContainer
                        : scheme.surfaceContainerHigh,
                    foregroundColor: c.isPlaying
                        ? scheme.onPrimaryContainer
                        : scheme.onSurfaceVariant,
                  ),
                  TonalButton(
                    size: TonalButtonSize.compact,
                    glyph: CallbookGlyphs.fullscreen,
                    label: '舞台演练',
                    onPressed: () => c.setPracticeMode(true),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _titleCtrl,
                decoration: const InputDecoration.collapsed(hintText: '曲目标题'),
                onChanged: (v) {
                  _lastSyncedTitle = v;
                  c.updateMeta(title: v);
                },
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _artistCtrl,
                decoration: const InputDecoration.collapsed(hintText: '艺人 / 团体'),
                onChanged: (v) {
                  _lastSyncedArtist = v;
                  c.updateMeta(artist: v);
                },
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  ScallopedOrbButton(
                    running: c.isPlaying,
                    size: 84,
                    onToggle: c.togglePlay,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          formatMsToClock(c.currentTimeMs),
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
                        const SizedBox(height: 2),
                        Text(
                          '/ ${formatMsToClock(safeDuration.round())} · ${c.statusMessage}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyle.caption1.of(context).copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            for (var b = 1; b <= beats; b++) ...[
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 110),
                                width: b == 1 ? 14 : 11,
                                height: b == 1 ? 14 : 11,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: c.isPlaying && c.currentBeatInBar == b
                                      ? (b == 1
                                            ? scheme.primary
                                            : scheme.secondary)
                                      : scheme.surfaceContainerHighest,
                                ),
                              ),
                              const SizedBox(width: 6),
                            ],
                            const Spacer(),
                            Text(
                              '${c.project.meta.bpm} BPM',
                              style: AppTextStyle.caption1
                                  .of(context, emphasized: true)
                                  .copyWith(
                                    fontFamily: 'GoogleSans',
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                    color: scheme.primary,
                                  ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Slider(
                value: clampedPos,
                min: 0,
                max: safeDuration,
                onChanged: (v) => c.seek(v.round()),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMetricsBento(
    BuildContext context,
    CallbookController c,
    ColorScheme scheme,
    int coveragePct,
  ) {
    final bpmCard = Card(
      inert: true,
      radius: 22,
      padding: EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: AppRadius.xl,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '节拍同步 · ${c.project.meta.bpm} BPM',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyle.subheadline
                              .of(context, emphasized: true)
                              .copyWith(color: scheme.onSurface),
                        ),
                      ),
                      TonalChip(
                        label: 'Tap 测速',
                        color: scheme.primaryContainer,
                        foregroundColor: scheme.onPrimaryContainer,
                        onPressed: c.tapTempo,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SizedBox(
                        width: 112,
                        child: SegmentedControl<String>(
                          segments: const [('4/4', '4/4'), ('3/4', '3/4')],
                          value: c.project.meta.timeSignature,
                          onChanged: c.setTimeSignature,
                        ),
                      ),
                      TonalChip(
                        label: '-5',
                        color: scheme.surfaceContainerHigh,
                        foregroundColor: scheme.onSurface,
                        onPressed: () => c.setBpm(c.project.meta.bpm - 5),
                      ),
                      TonalChip(
                        label: '+5',
                        color: scheme.surfaceContainerHigh,
                        foregroundColor: scheme.onSurface,
                        onPressed: () => c.setBpm(c.project.meta.bpm + 5),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            SparklineMetricFooter(
              values: c.beatPulseSeries,
              revision: c.beatSeriesRevision,
              color: scheme.primary,
              height: 48,
            ),
          ],
        ),
      ),
    );

    final coverageCard = Card(
      inert: true,
      radius: 22,
      padding: EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: AppRadius.xl,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '打标覆盖率 · $coveragePct%',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyle.subheadline
                              .of(context, emphasized: true)
                              .copyWith(color: scheme.onSurface),
                        ),
                      ),
                      TonalChip(
                        label: '${c.sortedAlerts.length} GT 警报',
                        color: scheme.warningContainer,
                        foregroundColor: scheme.onWarningContainer,
                        onPressed: () => c.insertGtAlert(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '${c.taggedLineCount} / ${c.project.lines.length} 行已配置 Call 动作 · 点击下方时间轴即可贴标',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyle.caption1.of(context).copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            SparklineMetricFooter(
              values: c.callDensitySeries,
              revision: c.callDensityRevision,
              color: scheme.tertiary,
              height: 48,
            ),
          ],
        ),
      ),
    );

    final metroCard = Card(
      inert: true,
      radius: 20,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '节拍器音频 (${(c.metronomeVolume * 100).round()}%)',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyle.subheadline
                      .of(context, emphasized: true)
                      .copyWith(color: scheme.onSurface),
                ),
              ),
              TonalChip(
                label: '试听',
                color: scheme.secondaryContainer,
                foregroundColor: scheme.onSecondaryContainer,
                onPressed: c.testMetronomeClick,
              ),
              const SizedBox(width: 8),
              Switch(
                value: c.metronomeEnabled,
                onChanged: c.setMetronomeEnabled,
                semanticLabel: '开启节拍器',
              ),
            ],
          ),
          const SizedBox(height: 6),
          Slider(
            value: c.metronomeVolume,
            min: 0.2,
            max: 1.5,
            onChanged: c.setMetronomeVolume,
          ),
        ],
      ),
    );

    final stageCard = Card(
      inert: true,
      radius: 20,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'GT 警报提示音',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyle.subheadline
                      .of(context, emphasized: true)
                      .copyWith(color: scheme.onSurface),
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
          Row(
            children: [
              Expanded(
                child: TonalButton(
                  size: TonalButtonSize.compact,
                  glyph: CallbookGlyphs.exportCard,
                  label: '速查卡与导出中心',
                  onPressed: () => c.setRoute(StudioRoute.export),
                ),
              ),
            ],
          ),
        ],
      ),
    );

    return LayoutBuilder(
      builder: (_, box) {
        if (box.maxWidth >= 500) {
          return Column(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: bpmCard),
                  const SizedBox(width: 12),
                  Expanded(child: coverageCard),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: metroCard),
                  const SizedBox(width: 12),
                  Expanded(child: stageCard),
                ],
              ),
            ],
          );
        }
        return Column(
          children: [
            bpmCard,
            const SizedBox(height: 12),
            coverageCard,
            const SizedBox(height: 12),
            metroCard,
            const SizedBox(height: 12),
            stageCard,
          ],
        );
      },
    );
  }

  Widget _buildControlStrip(
    BuildContext context,
    CallbookController c,
    ColorScheme scheme,
  ) {
    return Card(
      inert: true,
      radius: 20,
      padding: const EdgeInsets.all(14),
      child: Wrap(
        spacing: 14,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '倍速',
                style: AppTextStyle.caption1.of(context).copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 260,
                child: SegmentedControl<double>(
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
            ],
          ),
          Wrap(
            spacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '偏移 ${c.project.meta.offsetMs >= 0 ? "+" : ""}${c.project.meta.offsetMs}ms',
                style: AppTextStyle.caption1
                    .of(context, emphasized: true)
                    .copyWith(
                      fontFamily: 'GoogleSans',
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: scheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(width: 4),
              for (final delta in const [-100, -20])
                TonalChip(
                  label: '$delta',
                  color: scheme.surfaceContainerHigh,
                  foregroundColor: scheme.onSurface,
                  onPressed: () => c.adjustOffset(delta),
                ),
              TonalChip(
                label: '归零',
                color: scheme.surfaceContainerHigh,
                foregroundColor: scheme.onSurface,
                onPressed: () => c.setOffset(0),
              ),
              for (final delta in const [20, 100])
                TonalChip(
                  label: '+$delta',
                  color: scheme.surfaceContainerHigh,
                  foregroundColor: scheme.onSurface,
                  onPressed: () => c.adjustOffset(delta),
                ),
            ],
          ),
          Wrap(
            spacing: 6,
            children: [
              TonalChip(
                label: '注音 Ruby',
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
                label: '罗马音',
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
                label: '译文',
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
    required ValueChanged<String> onChanged,
    int maxLines = 1,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: AppTextStyle.caption1
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
                    '制作人员与编者信息',
                    style: AppTextStyle.headline
                        .of(context, emphasized: true)
                        .copyWith(color: scheme.onSurface),
                  ),
                ),
                TonalChip(
                  label: '速查卡同步',
                  color: scheme.primaryContainer,
                  foregroundColor: scheme.onPrimaryContainer,
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
                    hint: 'SAWTOWNE',
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
                    hint: 'SAWTOWNE',
                    controller: _lyricistCtrl,
                    focusNode: _lyricistFocus,
                    onChanged: (v) => c.updateMeta(lyricist: v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: _buildMetaInputField(
                    context,
                    scheme,
                    label: '演唱',
                    hint: '初音ミク',
                    controller: _vocalistCtrl,
                    focusNode: _vocalistFocus,
                    onChanged: (v) => c.updateMeta(vocalist: v),
                  ),
                ),
                const SizedBox(width: 8),
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
            if (showTuner) ...[
              const SizedBox(height: 8),
              _buildMetaInputField(
                context,
                scheme,
                label: '调教',
                hint: '输入调教 / 调声师',
                controller: _tunerCtrl,
                focusNode: _tunerFocus,
                onChanged: (v) => c.updateMeta(tuner: v),
              ),
            ],
            const SizedBox(height: 8),
            _buildMetaInputField(
              context,
              scheme,
              label: '编者',
              hint: '输入编者署名（导出前也可确认）',
              controller: _editorNameCtrl,
              focusNode: _editorNameFocus,
              onChanged: (v) => c.updateMeta(editorName: v),
            ),
            const SizedBox(height: 8),
            _buildMetaInputField(
              context,
              scheme,
              label: '编者语',
              hint: '输入给打 Call 观众的提示语（导出前也可确认）',
              controller: _editorNoteCtrl,
              focusNode: _editorNoteFocus,
              maxLines: 2,
              onChanged: (v) => c.updateMeta(editorNote: v),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSourceAndLrcColumn(
    BuildContext context,
    CallbookController c,
    ColorScheme scheme,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildCreditsAndEditorCard(context, c, scheme),
        const SizedBox(height: 12),
        Card(
          inert: true,
          radius: 22,
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '音源导入 · 曲库检索 & 本地文件',
                      style: AppTextStyle.headline
                          .of(context, emphasized: true)
                          .copyWith(color: scheme.onSurface),
                    ),
                  ),
                  TonalChip(
                    label: '演练 Demo',
                    color: scheme.secondaryContainer,
                    foregroundColor: scheme.onSecondaryContainer,
                    onPressed: () async {
                      final ok = await confirmArchiveSaveIfNeeded(
                        context,
                        c,
                        actionLabel: '加载演练 Demo',
                        targetLabel: '175 BPM 合成 Demo',
                      );
                      if (!ok || !mounted) return;
                      await c.loadDemoProject();
                    },
                  ),
                ],
              ),
              const SizedBox(height: 10),
              SegmentedControl<String>(
                segments: const [
                  ('auto', '自动聚合'),
                  ('custom_proxy', '网易云网关'),
                  ('lrclib', 'LRCLIB'),
                  ('mock', '演示库'),
                ],
                value: _searchSource,
                onChanged: (v) => setState(() => _searchSource = v),
              ),
              if (_searchSource == 'custom_proxy' &&
                  !c.gatewayStatus.gatewayOnline &&
                  !c.customProxyEnabled) ...[
                const SizedBox(height: 6),
                Text(
                  '提示：尚未检测到网易云网关在线，可在下方「网易云网关 & 曲库服务」卡片粘贴 Cookie 并一键启动。',
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
                        hintText: '搜索歌名 / 艺人 / Call 本曲目...',
                      ),
                      onSubmitted: (q) =>
                          c.searchTracks(q, source: _searchSource),
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
                    child: Text(c.isSearching ? '检索中' : '搜索'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TonalButton(
                size: TonalButtonSize.compact,
                glyph: CallbookGlyphs.musicNote,
                label: '导入本地音频 (MP3/WAV/FLAC)',
                onPressed: _pickLocalAudio,
              ),
              if (c.searchResults.isNotEmpty) ...[
                const SizedBox(height: 10),
                for (final track in c.searchResults.take(5))
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
                          label: '载入',
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
                          },
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),

        Card(
          inert: true,
          radius: 22,
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'LRC 歌词粘贴 & 日语注音生成',
                style: AppTextStyle.headline
                    .of(context, emphasized: true)
                    .copyWith(color: scheme.onSurface),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _lrcCtrl,
                maxLines: 4,
                minLines: 3,
                decoration: const InputDecoration(
                  hintText: '[00:12.40] 君と響く Starlight...',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _transCtrl,
                maxLines: 2,
                minLines: 2,
                decoration: const InputDecoration(
                  hintText: '可选：中文翻译 LRC（按时间戳自动对齐）',
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '导入后自动识别前/间/尾奏（前奏 ≥ ${(c.sectionThresholds.introThresholdMs / 1000).round()}s / 间奏 ≥ ${(c.sectionThresholds.interludeThresholdMs / 1000).round()}s / 尾奏 ≥ ${(c.sectionThresholds.outroThresholdMs / 1000).round()}s，可在工作台微调或手工添加）',
                style: AppTextStyle.caption1.of(context).copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 10),
              FilledButton(
                onPressed: () async {
                  if (_lrcCtrl.text.trim().isEmpty) return;
                  final ok = await confirmArchiveSaveIfNeeded(
                    context,
                    c,
                    actionLabel: '导入新 LRC 歌词',
                  );
                  if (!ok || !mounted) return;
                  await c.importLrcText(
                    lrc: _lrcCtrl.text,
                    translationLrc: _transCtrl.text,
                  );
                },
                child: const Text('解析 LRC 并更新当前时间轴'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        _buildGatewayConfigCard(context, c, scheme),
      ],
    );
  }
}
