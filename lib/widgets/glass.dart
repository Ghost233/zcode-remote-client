import 'dart:ui';

import 'package:flutter/material.dart';

/// iOS 材质风格的磨砂玻璃容器。
///
/// 关键点：模糊采样的是遮罩后面的真实内容——弹窗必须配浅色遮罩
/// （barrierColor: Colors.black26），否则模糊采到"被压暗的内容"，
/// 出来是一滩灰泥。填充用上亮下暗的渐变模拟 iOS 材质的光泽。
class GlassContainer extends StatelessWidget {
  const GlassContainer({
    super.key,
    required this.child,
    this.borderRadius = 22,
    this.padding,
    this.blur = 24,
    this.opacity,
  });

  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;
  final double blur;

  /// 覆盖默认底色不透明度（亮色 0.72 / 暗色 0.58）。
  final double? opacity;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = isDark ? Colors.black : Colors.white;
    final op = opacity ?? (isDark ? 0.58 : 0.72);
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            // 上亮下暗的渐变，模拟 iOS 材质顶部受光的效果
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                base.withValues(alpha: (op + 0.14).clamp(0.0, 1.0)),
                base.withValues(alpha: op),
              ],
            ),
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(
              color: Colors.white.withValues(alpha: isDark ? 0.16 : 0.55),
              width: 0.6,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          // 透明 Material：让 ListTile/InkWell 的墨水波纹在玻璃上正常绘制。
          child: Material(type: MaterialType.transparency, child: child),
        ),
      ),
    );
  }
}

/// 弹窗/底部面板统一用的玻璃遮罩参数：浅遮罩保住模糊后面的真实色彩。
const kGlassBarrierColor = Colors.black26;

/// 玻璃工具栏里用的小图标按钮。
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.size = 22,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: size),
      tooltip: tooltip,
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}
