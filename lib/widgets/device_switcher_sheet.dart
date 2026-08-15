import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/remote_device.dart';
import '../services/device_store.dart';
import 'device_edit_sheet.dart';
import 'glass.dart';

/// 点击悬浮球弹出的设备切换面板。
class DeviceSwitcherSheet extends StatelessWidget {
  const DeviceSwitcherSheet({
    super.key,
    required this.openIds,
    required this.onSelect,
    required this.onCloseSession,
    required this.onOpenSettings,
  });

  /// 当前已加载（保活中）的会话 id。
  final Set<String> openIds;
  final void Function(RemoteDevice device) onSelect;
  final void Function(RemoteDevice device) onCloseSession;
  final VoidCallback onOpenSettings;

  static Future<void> show(
    BuildContext context, {
    required Set<String> openIds,
    required void Function(RemoteDevice device) onSelect,
    required void Function(RemoteDevice device) onCloseSession,
    required VoidCallback onOpenSettings,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => DeviceSwitcherSheet(
        openIds: openIds,
        onSelect: onSelect,
        onCloseSession: onCloseSession,
        onOpenSettings: onOpenSettings,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<DeviceStore>();
    final devices = store.devices;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: GlassContainer(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            if (devices.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('还没有保存的设备，先添加一个吧'),
              )
            else
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.4,
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: devices.length,
                  itemBuilder: (context, index) {
                    final d = devices[index];
                    final isCurrent = d.id == store.currentId;
                    final isOpen = openIds.contains(d.id);
                    return ListTile(
                      leading: Icon(
                        isCurrent
                            ? Icons.terminal_rounded
                            : Icons.computer_rounded,
                        color: isCurrent
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                      title: Text(
                        store.displayName(d),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: isCurrent
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                      subtitle: Text(
                        isOpen
                            ? '${store.subtitle(d)} · 会话保持中'
                            : store.subtitle(d),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: isOpen
                          ? IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              tooltip: '关闭会话',
                              onPressed: () => onCloseSession(d),
                            )
                          : null,
                      onTap: () {
                        Navigator.of(context).pop();
                        onSelect(d);
                      },
                    );
                  },
                ),
              ),
            const Divider(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                TextButton.icon(
                  onPressed: () {
                    Navigator.of(context).pop();
                    DeviceEditSheet.show(context);
                  },
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('添加设备'),
                ),
                TextButton.icon(
                  onPressed: () {
                    Navigator.of(context).pop();
                    onOpenSettings();
                  },
                  icon: const Icon(Icons.settings_outlined, size: 18),
                  label: const Text('设置'),
                ),
                TextButton.icon(
                  onPressed: () {
                    Navigator.of(context).pop();
                    store.setBubbleEnabled(false);
                  },
                  icon: const Icon(Icons.visibility_off_outlined, size: 18),
                  label: const Text('隐藏控制栏'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
