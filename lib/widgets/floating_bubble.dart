import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/device_store.dart';
import 'glass.dart';

/// 可拖拽悬浮球：点击打开设备切换面板；松手自动吸附左右边缘；
/// 闲置几秒后半透明淡化；从设置/面板隐藏后变成细边把手，点把手恢复。
class FloatingBubble extends StatefulWidget {
  const FloatingBubble({super.key, required this.onTap});

  final VoidCallback onTap;

  static const double size = 52;

  @override
  State<FloatingBubble> createState() => _FloatingBubbleState();
}

class _FloatingBubbleState extends State<FloatingBubble>
    with SingleTickerProviderStateMixin {
  double? _dx; // 0..1，吸附后只会是 0 或 1
  double _dy = 0.35;
  bool _dragging = false;
  bool _dimmed = false;
  Timer? _idleTimer;

  @override
  void initState() {
    super.initState();
    _armIdleTimer();
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    super.dispose();
  }

  void _armIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && !_dragging) setState(() => _dimmed = true);
    });
  }

  void _wake() {
    if (_dimmed) setState(() => _dimmed = false);
    _armIdleTimer();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<DeviceStore>();
    _dx ??= store.bubbleDx ?? 1.0;
    if (store.bubbleDy != null && !_dragging && !_initialized) {
      _dy = store.bubbleDy!;
    }
    _initialized = true;

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxX = constraints.maxWidth - FloatingBubble.size;
        final maxY = constraints.maxHeight - FloatingBubble.size;
        final x = (_dx! * maxX).clamp(0.0, maxX);
        final y = (_dy * maxY).clamp(0.0, maxY);

        if (!store.bubbleEnabled) {
          // 隐藏模式：贴边细把手，点击恢复悬浮球。
          final pillHeight = 72.0;
          final pillY = (_dy * (constraints.maxHeight - pillHeight))
              .clamp(0.0, constraints.maxHeight - pillHeight);
          // Positioned 必须直接挂在 Stack 下，所以 LayoutBuilder 里包一层 Stack。
          return Stack(
            children: [
              Positioned(
                left: _dx == 0 ? 0 : null,
                right: _dx == 0 ? null : 0,
                top: pillY,
                child: GestureDetector(
                  onTap: () => store.setBubbleEnabled(true),
                  child: Container(
                    width: 8,
                    height: pillHeight,
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .primary
                          .withValues(alpha: 0.35),
                      borderRadius: BorderRadius.horizontal(
                        left:
                            _dx == 0 ? Radius.zero : const Radius.circular(6),
                        right:
                            _dx == 0 ? const Radius.circular(6) : Radius.zero,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        }

        return Stack(
          children: [
            Positioned(
              left: x,
              top: y,
              child: GestureDetector(
                onTap: () {
                  _wake();
                  widget.onTap();
                },
                onPanStart: (_) {
                  _dragging = true;
                  _wake();
                },
                onPanUpdate: (details) {
                  setState(() {
                    _dx = ((_dx! * maxX) + details.delta.dx) / maxX;
                    _dy = ((_dy * maxY) + details.delta.dy) / maxY;
                    _dx = _dx!.clamp(0.0, 1.0);
                    _dy = _dy.clamp(0.0, 1.0);
                  });
                },
                onPanEnd: (_) {
                  _dragging = false;
                  // 吸附到更近的一侧边缘。
                  final snapped = _dx! < 0.5 ? 0.0 : 1.0;
                  setState(() => _dx = snapped);
                  context
                      .read<DeviceStore>()
                      .setBubblePosition(snapped, _dy);
                  _armIdleTimer();
                },
                child: AnimatedOpacity(
                  opacity: _dimmed ? 0.35 : 1.0,
                  duration: const Duration(milliseconds: 400),
                  child: GlassContainer(
                    borderRadius: FloatingBubble.size / 2,
                    padding: EdgeInsets.zero,
                    child: SizedBox(
                      width: FloatingBubble.size,
                      height: FloatingBubble.size,
                      child: Icon(
                        Icons.terminal_rounded,
                        size: 26,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  bool _initialized = false;
}
