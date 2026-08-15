import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../models/remote_device.dart';
import '../services/device_store.dart';
import '../widgets/device_edit_sheet.dart';
import '../widgets/update_dialog.dart';

/// 设置页：设备管理（增删改、设为当前）+ 通用偏好。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  Future<void> _confirmDelete(BuildContext context, RemoteDevice device) async {
    final store = context.read<DeviceStore>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除设备'),
        content: Text('确定删除「${store.displayName(device)}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await context.read<DeviceStore>().remove(device.id);
    }
  }

  Future<void> _copyUrl(BuildContext context, RemoteDevice device) async {
    await Clipboard.setData(ClipboardData(text: device.url));
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已复制完整地址（含连接凭证，注意勿外泄）')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<DeviceStore>();
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: SafeArea(
        child: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                '已保存的远程地址',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            if (store.devices.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: Text('还没有保存任何地址')),
              )
            else
              ...store.devices.map(
                (d) => ListTile(
                  leading: Icon(
                    d.id == store.currentId
                        ? Icons.terminal_rounded
                        : Icons.computer_rounded,
                    color: d.id == store.currentId
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                  title: Text(
                    store.displayName(d),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${store.subtitle(d)} · 添加于 ${d.addedAt.toLocal().toString().substring(0, 16)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: PopupMenuButton<String>(
                    onSelected: (value) {
                      switch (value) {
                        case 'edit':
                          DeviceEditSheet.show(context, editing: d);
                          break;
                        case 'copy':
                          _copyUrl(context, d);
                          break;
                        case 'delete':
                          _confirmDelete(context, d);
                          break;
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('编辑 / 替换地址')),
                      PopupMenuItem(value: 'copy', child: Text('复制完整地址')),
                      PopupMenuItem(value: 'delete', child: Text('删除')),
                    ],
                  ),
                  onTap: () async {
                    await store.select(d.id);
                    if (context.mounted) Navigator.of(context).pop();
                  },
                ),
              ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: OutlinedButton.icon(
                onPressed: () => DeviceEditSheet.show(context),
                icon: const Icon(Icons.add),
                label: const Text('添加新地址'),
              ),
            ),
            const Divider(height: 32),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('通用', style: Theme.of(context).textTheme.titleSmall),
            ),
            SwitchListTile(
              title: const Text('显示悬浮控制栏'),
              subtitle: const Text('悬浮球与工具栏二合一；关闭后屏幕边缘会保留一个细把手，点击可恢复'),
              value: store.bubbleEnabled,
              onChanged: (v) => store.setBubbleEnabled(v),
            ),
            const Divider(height: 32),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('关于', style: Theme.of(context).textTheme.titleSmall),
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('当前版本'),
              subtitle: FutureBuilder<PackageInfo>(
                future: PackageInfo.fromPlatform(),
                builder: (context, snap) => Text(
                  snap.hasData
                      ? 'v${snap.data!.version} (${snap.data!.buildNumber})'
                      : '…',
                ),
              ),
              trailing: OutlinedButton.icon(
                onPressed: () => checkForUpdates(context, manual: true),
                icon: const Icon(Icons.system_update, size: 18),
                label: const Text('检查更新'),
              ),
            ),
            const Divider(height: 32),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              child: Text(
                '说明：地址中的 sid/hash 参数是连接凭证，会原样保存在本机；'
                '如果打开报错，说明地址可能已失效，长按设备选择「编辑 / 替换地址」录入新地址即可。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
