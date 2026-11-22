import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../state/callbook_controller.dart';
import '../theme/app_tokens.dart';

class GatewayConfigPanel extends StatefulWidget {
  const GatewayConfigPanel({
    super.key,
    required this.controller,
    this.collapsible = false,
  });

  final CallbookController controller;
  final bool collapsible;

  @override
  State<GatewayConfigPanel> createState() => _GatewayConfigPanelState();
}

class _GatewayConfigPanelState extends State<GatewayConfigPanel> {
  late final TextEditingController _neteaseCookieCtrl;
  final FocusNode _neteaseCookieFocus = FocusNode();

  String _lastSyncedCookie = '';
  bool _obscureCookie = true;
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = !widget.collapsible;
    final c = widget.controller;
    _neteaseCookieCtrl = TextEditingController(text: c.savedNeteaseCookie);
    _lastSyncedCookie = c.savedNeteaseCookie;
    c.gatewayListenable.addListener(_syncNetworkControllers);
  }

  @override
  void didUpdateWidget(covariant GatewayConfigPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.gatewayListenable.removeListener(
        _syncNetworkControllers,
      );
      widget.controller.gatewayListenable.addListener(_syncNetworkControllers);
    }
    if (oldWidget.collapsible != widget.collapsible && !widget.collapsible) {
      _expanded = true;
    }
    _syncNetworkControllers();
  }

  void _syncNetworkControllers() {
    final c = widget.controller;
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

  @override
  void dispose() {
    widget.controller.gatewayListenable.removeListener(_syncNetworkControllers);
    _neteaseCookieCtrl.dispose();
    _neteaseCookieFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return ListenableBuilder(
      listenable: c.gatewayListenable,
      builder: (context, _) {
        final scheme = context.colorScheme;
        final gw = c.gatewayStatus;
        final account = gw.neteaseAccount?.trim() ?? '';

        return Card(
          inert: true,
          radius: AppTokens.radiusCard,
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.collapsible)
                Semantics(
                  button: true,
                  label: _expanded ? '收起网络与注音配置' : '展开网络与注音配置',
                  child: PressSurface(
                    fill: const Color(0x00000000),
                    shape: AppShape.all(AppTokens.radiusSection),
                    tapTarget: AppTokens.minTapTargetSize,
                    onPressed: () => setState(() => _expanded = !_expanded),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '网易云直连与内置注音',
                                style: AppTextStyle.subheadline
                                    .of(context, emphasized: true)
                                    .copyWith(color: scheme.onSurface),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '直接连接与离线日语注音已就绪（点击展开配置）',
                                style: AppTextStyle.caption2
                                    .of(context)
                                    .copyWith(color: scheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                        TonalChip(
                          label: _expanded ? '收起' : '配置',
                          color: scheme.surfaceContainerHigh,
                          foregroundColor: scheme.onSurface,
                          onPressed: () =>
                              setState(() => _expanded = !_expanded),
                        ),
                      ],
                    ),
                  ),
                )
              else
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '网易云直连与内置注音',
                      style: AppTextStyle.headline
                          .of(context, emphasized: true)
                          .copyWith(color: scheme.onSurface),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '纯本地直连曲库 · 内置离线日语假名与罗马音引擎',
                      style: AppTextStyle.caption1.of(context).copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              if (_expanded) ...[
                const SizedBox(height: 10),
                Text(
                  '免配置后端：App 内置直接连接引擎检索网易云与 LRCLIB，并内置离线日语形态素词典自动标注假名与罗马音；粘贴 MUSIC_U 可登录账号解锁完整试听。',
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
                      label: '直接连接',
                      color: scheme.primaryContainer,
                      foregroundColor: scheme.onPrimaryContainer,
                    ),
                    TonalChip(
                      label: c.offlineRubyEnabled ? '内置注音就绪' : '离线注音已关',
                      color: c.offlineRubyEnabled
                          ? scheme.successContainer
                          : scheme.surfaceContainerHigh,
                      foregroundColor: c.offlineRubyEnabled
                          ? scheme.onSuccessContainer
                          : scheme.onSurfaceVariant,
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
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: ShapeDecoration(
                    color: SurfaceLevel.block.colorOf(scheme),
                    shape: AppShape.md,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _SettingSwitchRow(
                        title: '内置离线日语注音（Ruby / 罗马音）',
                        subtitle: '搜歌或导入日语 LRC 时自动生成假名注音与罗马音，纯中文歌词自动跳过',
                        value: c.offlineRubyEnabled,
                        onChanged: c.setOfflineRubyEnabled,
                      ),
                      const SizedBox(height: 10),
                      _SettingSwitchRow(
                        title: '优先使用网易云自带罗马音（romalrc）',
                        subtitle: '网易云曲库返回官方罗马音时优先采用，缺失行由内置离线引擎补全',
                        value: c.preferNeteaseRomaLrc,
                        onChanged: c.setPreferNeteaseRomaLrc,
                      ),
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TonalButton(
                          size: TonalButtonSize.compact,
                          label: c.isAnnotatingRuby
                              ? '正在生成日语注音…'
                              : '为当前歌曲生成 / 刷新日语注音',
                          onPressed: c.isAnnotatingRuby
                              ? null
                              : () => c.annotateCurrentProjectLyrics(),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
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
                      onPressed: () =>
                          setState(() => _neteaseCookieCtrl.clear()),
                    ),
                    TonalButton(
                      size: TonalButtonSize.compact,
                      label: '检测直连状态',
                      onPressed: () =>
                          c.refreshGatewayStatus(probeDirect: true),
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
                          );
                        },
                  child: Text(
                    c.isConfiguringGateway
                        ? '正在验证与保存...'
                        : '验证并保存 Cookie（直接连接）',
                  ),
                ),
                if (gw.message.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    gw.message,
                    style: AppTextStyle.caption1.of(context).copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ],
          ),
        );
      },
    );
  }
}

class _SettingSwitchRow extends StatelessWidget {
  const _SettingSwitchRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: AppTextStyle.caption1
                    .of(context, emphasized: true)
                    .copyWith(color: scheme.onSurface),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: AppTextStyle.caption2.of(context).copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Switch(value: value, onChanged: onChanged, semanticLabel: title),
      ],
    );
  }
}
