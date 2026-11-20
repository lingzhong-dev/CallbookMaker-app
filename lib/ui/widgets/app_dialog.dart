import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart';

/// Unified modal dialog entry point powered by `prism_ui`'s [showFloatingDialog].
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool dismissible = true,
}) {
  return showFloatingDialog<T>(
    context: context,
    dismissible: dismissible,
    child: Builder(builder: builder),
  );
}

/// Shows a draggable [SnapSheetRoute] on narrow screens (`width < 600`) and
/// falls back to [showAppDialog] on larger viewports.
Future<T?> showAppAdaptiveSheetOrDialog<T>({
  required BuildContext context,
  required WidgetBuilder dialogBuilder,
  required Widget Function(BuildContext sheetContext, ScrollController? scrollController)
  sheetBuilder,
  bool dismissible = true,
  List<double> detents = const [0.76, 0.94],
  bool fitsContent = false,
}) {
  if (MediaQuery.sizeOf(context).width < 600) {
    final scheme = context.colorScheme;
    return sheetNavigatorOf(context).push<T>(
      SnapSheetRoute<T>(
        sheetBarrierColor: scheme.modalScrim,
        barrierLabel: '关闭',
        detents: detents,
        fitsContent: fitsContent,
        builder: (sheetCtx, scrollController) => SafeArea(
          top: false,
          child: sheetBuilder(sheetCtx, scrollController),
        ),
      ),
    );
  }
  return showAppDialog<T>(
    context: context,
    dismissible: dismissible,
    builder: dialogBuilder,
  );
}
