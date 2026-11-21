import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:prism_ui/icons/icons.dart';
import 'package:prism_ui/prism_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constants/app_info.dart';
import '../platform/app_platform.dart';
import '../state/callbook_controller.dart';
import 'theme/app_tokens.dart';
import 'theme_view.dart';
import 'widgets/app_dialog.dart';
import 'widgets/callbook_glyphs.dart';
import 'widgets/gateway_config_panel.dart';

enum _MoreSubPage { root, gateway, theme, about }

class MoreView extends StatefulWidget {
  const MoreView({
    super.key,
    required this.controller,
    this.rootResetNonce = 0,
    this.onLaunchExternalUrl,
  });

  final CallbookController controller;
  final int rootResetNonce;
  final Future<void> Function(String url)? onLaunchExternalUrl;

  @override
  State<MoreView> createState() => _MoreViewState();
}

class _MoreViewState extends State<MoreView> {
  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();

  @override
  void didUpdateWidget(covariant MoreView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.rootResetNonce != oldWidget.rootResetNonce) {
      _navKey.currentState?.popUntil((route) => route.isFirst);
    }
  }

  Future<void> _openGithubUrl() async {
    await Clipboard.setData(const ClipboardData(text: kDeveloperGithubUrl));
    widget.controller.setStatus('已复制 GitHub 主页链接 ($kDeveloperGithubUrl)');
    widget.controller.notify(
      '已复制 GitHub 主页链接',
      level: BannerLevel.success,
    );

    if (widget.onLaunchExternalUrl != null) {
      await widget.onLaunchExternalUrl!(kDeveloperGithubUrl);
      return;
    }

    // Never spawn OS browser processes inside automated widget tests.
    if (AppPlatform.isWidgetTest) return;

    try {
      await launchUrl(
        Uri.parse(kDeveloperGithubUrl),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      // Clipboard copy above already notified the user.
    }
  }

  Future<void> _showLicenseDialog(BuildContext context) async {
    final scheme = context.colorScheme;
    await showAppDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: '$kAppLicenseName 开源协议',
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('关闭'),
          ),
        ],
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'GNU GENERAL PUBLIC LICENSE\nVersion 3, 29 June 2007',
                  style: AppTextStyle.subheadline
                      .of(dialogCtx, emphasized: true)
                      .copyWith(color: scheme.onSurface),
                ),
                const SizedBox(height: 8),
                Text(
                  'CallbookMaker（Version $kAppVersion）依据 GNU GPL v3.0 自由软件开源协议发布。'
                  '你可以自由运行、研究、修改并分发本软件及其衍生版本，前提是衍生作品同样遵循 GPL v3.0 协议并公开对应源代码。',
                  style: AppTextStyle.caption1.of(dialogCtx).copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Copyright (C) 2025-2026 $kDeveloperGithubId\n'
                  'Repository License: GNU General Public License v3.0\n'
                  'This program comes with ABSOLUTELY NO WARRANTY.',
                  style: AppTextStyle.caption2.of(dialogCtx).copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openSubPage(BuildContext navCtx, _MoreSubPage page) {
    Navigator.of(navCtx).push<void>(
      CardPageRoute<void>(
        builder: (routeCtx) => switch (page) {
          _MoreSubPage.root => _buildRootMenu(routeCtx),
          _MoreSubPage.gateway => _buildSubPageScaffold(
            routeCtx,
            title: '网关配置',
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                16,
                4,
                16,
                20 + BottomInsetScope.of(routeCtx),
              ),
              child: GatewayConfigPanel(
                controller: widget.controller,
                collapsible: false,
              ),
            ),
          ),
          _MoreSubPage.theme => _buildSubPageScaffold(
            routeCtx,
            title: '主题',
            child: ThemeView(controller: widget.controller),
          ),
          _MoreSubPage.about => _buildAboutPage(routeCtx),
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _navKey.currentState?.maybePop();
        }
      },
      child: Navigator(
        key: _navKey,
        onGenerateInitialRoutes: (navigator, initialRoute) => [
          PageRouteBuilder<void>(
            pageBuilder: (navCtx, _, _) => _buildRootMenu(navCtx),
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
          ),
        ],
      ),
    );
  }

  Widget _buildRootMenu(BuildContext context) {
    final c = widget.controller;
    final scheme = context.colorScheme;
    final bottomInset = BottomInsetScope.of(context);

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(16, 4, 16, 20 + bottomInset),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            inert: true,
            radius: AppTokens.radiusCard,
            padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _MoreMenuRow(
                  glyph: CallbookGlyphs.gateway,
                  iconBackground: scheme.primaryContainer,
                  iconColor: scheme.onPrimaryContainer,
                  title: c.siteText('网关配置'),
                  subtitle: c.backendOnline
                      ? '后端注音在线 · 支持直接连接'
                      : '配置网易云网关',
                  onTap: () => _openSubPage(context, _MoreSubPage.gateway),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Container(
                    height: 1,
                    color: scheme.outlineVariant.withValues(alpha: 0.45),
                  ),
                ),
                _MoreMenuRow(
                  glyph: CallbookGlyphs.theme,
                  iconBackground: scheme.secondaryContainer,
                  iconColor: scheme.onSecondaryContainer,
                  title: c.siteText('主题'),
                  subtitle: '更改主题色与其他高级设置',
                  onTap: () => _openSubPage(context, _MoreSubPage.theme),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Container(
                    height: 1,
                    color: scheme.outlineVariant.withValues(alpha: 0.45),
                  ),
                ),
                _MoreMenuRow(
                  glyph: CallbookGlyphs.info,
                  iconBackground: scheme.surfaceContainerHigh,
                  iconColor: scheme.primary,
                  title: c.siteText('关于'),
                  subtitle: '关于CallbookMaker',
                  onTap: () => _openSubPage(context, _MoreSubPage.about),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubPageScaffold(
    BuildContext context, {
    required String title,
    required Widget child,
  }) {
    final scheme = context.colorScheme;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
      },
      child: DecoratedBox(
        decoration: BoxDecoration(color: SurfaceLevel.page.colorOf(scheme)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 16, 8),
              child: Row(
                children: [
                  _BackChevronButton(
                    semanticLabel: '返回更多',
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    title,
                    style: AppTextStyle.headline
                        .of(context, emphasized: true)
                        .copyWith(color: scheme.onSurface),
                  ),
                ],
              ),
            ),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }

  Widget _buildAboutPage(BuildContext context) {
    final scheme = context.colorScheme;
    final bottomInset = BottomInsetScope.of(context);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
      },
      child: DecoratedBox(
        decoration: BoxDecoration(color: SurfaceLevel.page.colorOf(scheme)),
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 20 + bottomInset),
              sliver: SliverFillRemaining(
                hasScrollBody: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _BackChevronButton(
                        semanticLabel: '返回更多',
                        onTap: () => Navigator.of(context).maybePop(),
                      ),
                    ),
                const SizedBox(height: 12),

                // Upper Section (matched to reference layout: centered rounded icon + App Name + Version)
                Center(
                  child: Container(
                    width: 72,
                    height: 72,
                    decoration: ShapeDecoration(
                      color: scheme.surfaceContainerHigh,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                        side: BorderSide(
                          color: scheme.outlineVariant.withValues(alpha: 0.4),
                        ),
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Image.asset(
                      'assets/images/icon.png',
                      width: 72,
                      height: 72,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  kAppDisplayName,
                  textAlign: TextAlign.center,
                  style: AppTextStyle.title1
                      .of(context, emphasized: true)
                      .copyWith(color: scheme.onSurface),
                ),
                const SizedBox(height: 6),
                Text(
                  'Version $kAppVersion',
                  textAlign: TextAlign.center,
                  style: AppTextStyle.subheadline.of(context).copyWith(
                    color: scheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 28),
                Container(
                  height: 1,
                  color: scheme.outlineVariant.withValues(alpha: 0.4),
                ),

                // Middle Section: Developer Info (GitHub Avatar, ID, clickable Link)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Row(
                    children: [
                      ClipOval(
                        child: Image.network(
                          kDeveloperGithubAvatarUrl,
                          width: 44,
                          height: 44,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Container(
                            width: 44,
                            height: 44,
                            color: scheme.primaryContainer,
                            alignment: Alignment.center,
                            child: Text(
                              'LZ',
                              style: AppTextStyle.subheadline
                                  .of(context, emphasized: true)
                                  .copyWith(color: scheme.onPrimaryContainer),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '开发者',
                              style: AppTextStyle.caption1.of(context).copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              kDeveloperGithubId,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTextStyle.subheadline
                                  .of(context, emphasized: true)
                                  .copyWith(color: scheme.onSurface),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: ShapeDecoration(
                          color: scheme.surfaceContainerHigh,
                          shape: AppShape.full,
                        ),
                        child: Text(
                          'GitHub',
                          style: AppTextStyle.caption2
                              .of(context, emphasized: true)
                              .copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  height: 1,
                  color: scheme.outlineVariant.withValues(alpha: 0.35),
                ),
                Semantics(
                  button: true,
                  label: '打开 GitHub 主页 $kDeveloperGithubUrl',
                  child: PressSurface(
                    fill: const Color(0x00000000),
                    shape: AppShape.sm,
                    tapTarget: AppTokens.minTapTargetSize,
                    onPressed: _openGithubUrl,
                    child: ListRow(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      title: const Text('GitHub 主页'),
                      subtitle: Text(
                        kDeveloperGithubUrl,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyle.caption1
                            .of(context)
                            .copyWith(color: scheme.primary),
                      ),
                      trailing: GlyphIcon(
                        Glyphs.chevronForward,
                        size: 16,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                Container(
                  height: 1,
                  color: scheme.outlineVariant.withValues(alpha: 0.4),
                ),

                const Expanded(child: SizedBox(height: 36)),

                // Bottom Section: Current App Version + Open Source License
                Center(
                  child: Semantics(
                    button: true,
                    label: '查看 $kAppLicenseName 开源协议',
                    child: PressSurface(
                      fill: const Color(0x00000000),
                      shape: AppShape.sm,
                      tapTarget: AppTokens.minTapTargetSize,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      onPressed: () => _showLicenseDialog(context),
                      child: Text(
                        '《$kAppLicenseName 开源协议》',
                        textAlign: TextAlign.center,
                        style: AppTextStyle.caption1
                            .of(context, emphasized: true)
                            .copyWith(color: scheme.primary),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '当前版本 Version $kAppVersion · 遵循 $kAppLicenseName 开源协议',
                  textAlign: TextAlign.center,
                  style: AppTextStyle.caption2.of(context).copyWith(
                    color: scheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'LingZhong · CallbookMaker',
                  textAlign: TextAlign.center,
                  style: AppTextStyle.caption2.of(context).copyWith(
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
      ),
    );
  }
}

class _MoreMenuRow extends StatelessWidget {
  const _MoreMenuRow({
    required this.glyph,
    required this.iconBackground,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final Glyph glyph;
  final Color iconBackground;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    return Semantics(
      button: true,
      label: title,
      child: PressSurface(
        fill: const Color(0x00000000),
        shape: AppShape.sm,
        tapTarget: AppTokens.minTapTargetSize,
        onPressed: onTap,
        child: ListRow(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          leading: Container(
            width: 38,
            height: 38,
            decoration: ShapeDecoration(
              color: iconBackground,
              shape: AppShape.all(12),
            ),
            alignment: Alignment.center,
            child: GlyphIcon(glyph, size: 19, color: iconColor),
          ),
          title: Text(title),
          subtitle: Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: GlyphIcon(
            Glyphs.chevronForward,
            size: 16,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _BackChevronButton extends StatelessWidget {
  const _BackChevronButton({
    required this.semanticLabel,
    required this.onTap,
  });

  final String semanticLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    return Semantics(
      container: true,
      label: semanticLabel,
      button: true,
      excludeSemantics: true,
      child: IconButton(
        tooltip: semanticLabel,
        icon: GlyphIcon(
          Glyphs.chevronBack,
          size: 18,
          color: scheme.onSurface,
        ),
        style: ButtonStyle(
          backgroundColor: WidgetStatePropertyAll(
            scheme.surfaceContainerHigh.withValues(alpha: 0.55),
          ),
          shape: AppShape.circle,
          minimumSize: AppTokens.minTapTargetSize,
          fixedSize: const Size(38, 38),
          tapTargetSize: TapTargetSize.padded,
        ),
        onPressed: onTap,
      ),
    );
  }
}
