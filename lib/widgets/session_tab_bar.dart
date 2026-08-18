
import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import 'glass.dart';

/// 单个会话页签的数据。
class SessionTab {
  const SessionTab({required this.id, required this.label});

  final String id;
  final String label;
}

/// 浏览器风格的会话页签栏。
///
/// 玻璃材质横条。单屏时钉在页面最顶部（避让状态栏）；分屏时左右
/// 窗格顶部各有一条，各自切换/刷新本窗格显示的会话。会话过多时
/// 横向滚动，本窗格正在显示的页签高亮；每个页签可关闭、可拖动
/// （拖到另一个窗格松手即把该会话挪过去；手机上长按页签才进入
/// 拖动，直接划动是滚动列表，桌面端按下即可拖）；最右「+」打开
/// 会话切换面板（选已有设备 / 新建 / 关闭会话的统一入口）。
class SessionTabBar extends StatelessWidget {
  const SessionTabBar({
    super.key,
    required this.tabs,
    required this.activeId,
    required this.onSelect,
    required this.onClose,
    required this.onAdd,
    required this.onRefresh,
    required this.splitActive,
    required this.splitEnabled,
    required this.onToggleSplit,
  });

  final List<SessionTab> tabs;
  final String? activeId;

  /// 点击页签切换会话。
  final void Function(String id) onSelect;

  /// 点击页签上的 × 关闭会话（当前会话也可关，关闭逻辑由外部处理）。
  final void Function(String id) onClose;

  /// 点击 + 打开会话切换面板。
  final VoidCallback onAdd;

  /// 刷新当前会话。
  final VoidCallback onRefresh;

  /// 左右分屏开关状态与回调（分屏中窗格页签栏上表现为「退出分屏」）。
  final bool splitActive;
  final bool splitEnabled;
  final VoidCallback onToggleSplit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GlassContainer(
      borderRadius: 0,
      blur: 30,
      child: SizedBox(
        height: 38,
        child: Row(
          children: [
            Expanded(
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: tabs.length,
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 4,
                ),
                itemBuilder: (context, index) {
                  final tab = tabs[index];
                  final active = tab.id == activeId;
                  final chip = Material(
                    color: active
                        ? scheme.primary.withValues(alpha: 0.85)
                        : scheme.surfaceContainerHighest.withValues(
                            alpha: 0.45,
                          ),
                    borderRadius: BorderRadius.circular(10),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => onSelect(tab.id),
                      child: Padding(
                        padding: const EdgeInsets.only(left: 10),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ConstrainedBox(
                              constraints: const BoxConstraints(
                                maxWidth: 140,
                              ),
                              child: Text(
                                tab.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.labelMedium
                                    ?.copyWith(
                                      fontWeight: active
                                          ? FontWeight.w600
                                          : FontWeight.w500,
                                    ),
                              ),
                            ),
                            const SizedBox(width: 2),
                            _CloseDot(onClose: () => onClose(tab.id)),
                          ],
                        ),
                      ),
                    ),
                  );
                  // 可拖动：拖到另一个分屏窗格（DragTarget 接收区）松手
                  // 即挪过去，拖到别处取消。手机上「按下即拖」会抢走 tab
                  // 栏的横向滚动手势（想滚动反而把页签拖起来），所以手机
                  // 长按页签才进入拖动；桌面端鼠标拖与滚轮滚动不冲突，
                  // 保持按下即可拖。
                  final feedback = Opacity(
                    opacity: 0.85,
                    child: Material(color: Colors.transparent, child: chip),
                  );
                  final dragging = Opacity(opacity: 0.35, child: chip);
                  return Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Platform.isAndroid || Platform.isIOS
                        ? LongPressDraggable<String>(
                            data: tab.id,
                            // 拖拽中跟随指尖的半透明页签
                            feedback: feedback,
                            childWhenDragging: dragging,
                            child: chip,
                          )
                        : Draggable<String>(
                            data: tab.id,
                            feedback: feedback,
                            childWhenDragging: dragging,
                            child: chip,
                          ),
                  );
                },
              ),
            ),
            // 刷新当前会话
            IconButton(
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              tooltip: '刷新',
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh),
            ),
            // 左右分屏：当前会话在左，另一会话在右，中间可拖分隔
            IconButton(
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              tooltip: splitActive ? '退出分屏' : '左右分屏',
              onPressed: splitEnabled ? onToggleSplit : null,
              icon: Icon(
                splitActive
                    ? Icons.vertical_split
                    : Icons.vertical_split_outlined,
                color: splitActive
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
            ),
            // 「+」：打开会话切换面板（选设备/新建/管理会话的统一入口）
            IconButton(
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              tooltip: '切换 / 新建会话',
              onPressed: onAdd,
              icon: const Icon(Icons.add),
            ),
          ],
        ),
      ),
    );
  }
}

/// 页签右侧的小关闭点：hover/按压时显形，避免误触。
class _CloseDot extends StatelessWidget {
  const _CloseDot({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(9),
      onTap: onClose,
      child: const SizedBox(
        width: 18,
        height: 18,
        child: Icon(Icons.close, size: 13),
      ),
    );
  }
}
