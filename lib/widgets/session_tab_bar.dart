
import 'package:flutter/material.dart';

import 'glass.dart';

/// 单个会话页签的数据。
class SessionTab {
  const SessionTab({required this.id, required this.label});

  final String id;
  final String label;
}

/// 浏览器风格的顶部会话页签栏。
///
/// 玻璃材质横条，钉在页面最顶部（避让状态栏）：会话过多时横向滚动，
/// 当前会话高亮；每个页签可关闭；最右「+」打开会话切换面板
/// （选已有设备 / 新建 / 关闭会话的统一入口）。
class SessionTabBar extends StatelessWidget {
  const SessionTabBar({
    super.key,
    required this.tabs,
    required this.activeId,
    required this.onSelect,
    required this.onClose,
    required this.onAdd,
  });

  final List<SessionTab> tabs;
  final String? activeId;

  /// 点击页签切换会话。
  final void Function(String id) onSelect;

  /// 点击页签上的 × 关闭会话（当前会话也可关，关闭逻辑由外部处理）。
  final void Function(String id) onClose;

  /// 点击 + 打开会话切换面板。
  final VoidCallback onAdd;

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
                  return Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Material(
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
                    ),
                  );
                },
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
