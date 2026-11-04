import 'package:flutter/widgets.dart';

/// 与原 Compose AlertDialog 对齐的弹窗尺寸策略：
/// - 水平只留 16dp（Compose 默认 24dp 边距，但 Flutter AlertDialog 自身
///   还有 contentPadding，留 16 才能接近原弹窗的可视宽度）；
/// - 宽度用满可用空间，不再写死 420/460；
/// - 高度包裹内容，最高不超过屏幕的 72%，超出后内部滚动。
const EdgeInsets kDialogInsetPadding = EdgeInsets.symmetric(
  horizontal: 16,
  vertical: 24,
);

BoxConstraints dialogContentConstraints(
  BuildContext context, {
  double maxWidth = 560,
  double maxHeightFactor = 0.72,
  double? maxHeightOverride,
}) {
  final screen = MediaQuery.sizeOf(context);
  return BoxConstraints(
    maxWidth: maxWidth,
    maxHeight:
        maxHeightOverride ?? (screen.height * maxHeightFactor).clamp(240, 720),
  );
}

/// 标准内容容器：占满弹窗宽度，高度按内容但受上限约束。
class DialogContent extends StatelessWidget {
  const DialogContent({
    super.key,
    required this.child,
    this.maxWidth = 560,
    this.maxHeightFactor = 0.72,
    this.maxHeightOverride,
  });

  final Widget child;
  final double maxWidth;
  final double maxHeightFactor;
  final double? maxHeightOverride;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.maxFinite,
      child: ConstrainedBox(
        constraints: dialogContentConstraints(
          context,
          maxWidth: maxWidth,
          maxHeightFactor: maxHeightFactor,
          maxHeightOverride: maxHeightOverride,
        ),
        child: child,
      ),
    );
  }
}
