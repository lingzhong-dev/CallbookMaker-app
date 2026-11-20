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
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = !widget.collapsible;
    final c = widget.controller;
    _backendCtrl = TextEditingController(text: c.backendUrl);
    _gatewayUrlCtrl = TextEditingController(text: c.savedGatewayUrl);
    _neteaseCookieCtrl = TextEditingController(text: c.savedNeteaseCookie);
    _lastSyncedBackendUrl = c.backendUrl;
    _lastSyncedGatewayUrl = c.savedGatewayUrl;
    _lastSyncedCookie = c.savedNeteaseCookie;
    c.gatewayListenable.addListener(_syncNetworkControllers);
    _backendUrlFocus.addListener(_onBackendUrlFocusChanged);
  }

  void _onBackendUrlFocusChanged() {
    if (!_backendUrlFocus.hasFocus && mounted) {
      final trimmed = _backendCtrl.text.trim();
      if (trimmed.isNotEmpty && trimmed != widget.controller.backendUrl) {
        widget.controller.setBackendUrl(trimmed);
      }
    }
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

  @override
  void dispose() {
    widget.controller.gatewayListenable.removeListener(_syncNetworkControllers);
    _backendUrlFocus.removeListener(_onBackendUrlFocusChanged);
    _backendCtrl.dispose();
    _gatewayUrlCtrl.dispose();
    _neteaseCookieCtrl.dispose();
    _backendUrlFocus.dispose();
    _gatewayUrlFocus.dispose();
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
        final isDesktop = c.isDesktopHost;
        final account = gw.neteaseAccount?.trim() ?? '';
        final backendNodeGatewayActive =
            c.backendOnline &&
            (gw.managedByBackend || (gw.gatewayOnline && gw.nodeAvailable));

        return Card(
      inert: true,
      radius: AppTokens.radiusCard,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.collapsible)
            GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
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
                    label: _expanded ? '收起' : '配置',
                    color: scheme.surfaceContainerHigh,
                    foregroundColor: scheme.onSurface,
                    onPressed: () => setState(() => _expanded = !_expanded),
                  ),
                ],
              ),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '网易云直连 & 可选后端服务',
                  style: AppTextStyle.headline
                      .of(context, emphasized: true)
                      .copyWith(color: scheme.onSurface),
                ),
                const SizedBox(height: 2),
                Text(
                  c.backendOnline
                      ? '后端注音在线 · 支持纯 Dart 直连'
                      : '纯 Dart 引擎直连就绪 · 可选接入 FastAPI 注音服务',
                  style: AppTextStyle.caption1.of(context).copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          if (_expanded) ...[
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
      },
    );
  }
}
