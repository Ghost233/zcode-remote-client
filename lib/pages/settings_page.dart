import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../models/remote_device.dart';
import '../services/device_store.dart';
import '../services/download_manager.dart';
import '../services/process_memory.dart';
import '../services/update_checker.dart';
import '../widgets/device_edit_sheet.dart';
import '../widgets/update_dialog.dart';

/// 设置页：设备管理（增删改、设为当前）+ 通用偏好 + 应用/更新。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  @override
  void initState() {
    super.initState();
    // 下载全部重试失败时的弹窗只在本页弹出（其余场景走通知栏）。
    DownloadManager.instance.settingsFailurePresenter = _onDownloadFailed;
  }

  @override
  void dispose() {
    final dm = DownloadManager.instance;
    if (dm.settingsFailurePresenter == _onDownloadFailed) {
      dm.settingsFailurePresenter = null;
    }
    super.dispose();
  }

  void _onDownloadFailed() {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) {
        final dm = DownloadManager.instance;
        return AlertDialog(
          title: const Text('更新下载失败'),
          content: const Text(
            '网络不佳，自动重试多次仍未成功。\n要删除后重新下载，还是从断点继续重试？',
            style: TextStyle(fontSize: 13, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('稍后'),
            ),
            OutlinedButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                dm.deleteAndRestart();
              },
              child: const Text('删除重新下载'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                dm.retry();
              },
              child: const Text('继续重试'),
            ),
          ],
        );
      },
    );
  }

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

  String _mb(int bytes) => (bytes / 1048576).toStringAsFixed(1);

  /// 下载状态卡片：下载中（进度+取消）/ 已暂停（继续）/ 失败（重试、
  /// 删除重下）/ 已完成未安装（立即安装）。仅在非 idle 时由外层调用。
  Widget _buildUpdateStatusCard() {
    final dm = DownloadManager.instance;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: Theme.of(
            context,
          ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        ),
        child: ListenableBuilder(
          listenable: Listenable.merge([
            dm.status,
            dm.receivedBytes,
            dm.totalBytes,
          ]),
          builder: (context, _) {
            final s = dm.status.value;
            final received = dm.receivedBytes.value;
            final total = dm.totalBytes.value;
            final pct = total > 0 ? received * 100 ~/ total : 0;
            final version = dm.release?.version ?? '';
            switch (s) {
              case DownloadStatus.downloading:
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '正在后台下载 v$version · $pct%',
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                        TextButton(
                          onPressed: dm.cancel,
                          child: const Text('取消'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: total > 0
                          ? (received / total).clamp(0.0, 1.0)
                          : null,
                    ),
                  ],
                );
              case DownloadStatus.cancelled:
                return Row(
                  children: [
                    const Icon(Icons.pause_circle_outline, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '更新下载已暂停 · 已下载 $pct% (${_mb(received)} MB)',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    FilledButton.tonal(
                      onPressed: () => dm.retry(),
                      child: const Text('继续下载'),
                    ),
                  ],
                );
              case DownloadStatus.failed:
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.error_outline,
                          size: 20,
                          color: Theme.of(context).colorScheme.error,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '更新下载失败（网络不佳，已自动重试多次）',
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => dm.deleteAndRestart(),
                          child: const Text('删除重新下载'),
                        ),
                        FilledButton.tonal(
                          onPressed: () => dm.retry(),
                          child: const Text('从断点重试'),
                        ),
                      ],
                    ),
                  ],
                );
              case DownloadStatus.completed:
                return Row(
                  children: [
                    Icon(
                      Icons.check_circle_outline,
                      size: 20,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'v$version 已下载完成，尚未安装',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: () => dm.promptInstall(),
                      icon: const Icon(Icons.install_mobile, size: 18),
                      label: const Text('安装'),
                    ),
                  ],
                );
              case DownloadStatus.idle:
                return const SizedBox.shrink();
            }
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<DeviceStore>();
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: SafeArea(
        child: ListView(
          children: [
            const _MemoryTile(),
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
                label: Text('添加新地址'),
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
                builder: (context, snap) {
                  if (!snap.hasData) return const Text('…');
                  final info = snap.data!;
                  // 构建短哈希由 CI 注入（--dart-define=BUILD_HASH），
                  // 本地 flutter run 时为空。
                  final hash = kBuildHash.isEmpty ? '' : ' · $kBuildHash';
                  return Text('v${info.version} · 构建 ${info.buildNumber}$hash');
                },
              ),
              trailing: OutlinedButton.icon(
                onPressed: () => checkForUpdates(context, manual: true),
                icon: const Icon(Icons.system_update, size: 18),
                label: const Text('检查更新'),
              ),
            ),
            // 下载状态卡片（下载中/已暂停/失败/待安装）。
            ValueListenableBuilder<DownloadStatus>(
              valueListenable: DownloadManager.instance.status,
              builder: (context, s, _) => s == DownloadStatus.idle
                  ? const SizedBox.shrink()
                  : _buildUpdateStatusCard(),
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

/// 内存占用条目：展示应用全部进程的 RSS 总和，每 2 秒自动刷新，
/// 点击立即刷新。用于观察内存趋势（排查泄漏时留意持续单调上涨）。
/// Android 口径含 WebView 渲染进程；iOS 取不到时显示不可用。
class _MemoryTile extends StatefulWidget {
  const _MemoryTile();

  @override
  State<_MemoryTile> createState() => _MemoryTileState();
}

class _MemoryTileState extends State<_MemoryTile> {
  String _text = '…';
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final bytes = await ProcessMemory.rssBytes();
    if (!mounted) return;
    setState(() {
      _text = bytes == null
          ? '本平台暂不支持'
          : bytes >= 1073741824
          ? '${(bytes / 1073741824).toStringAsFixed(2)} GB'
          : '${(bytes / 1048576).toStringAsFixed(1)} MB';
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: const Icon(Icons.memory_outlined),
      title: const Text('内存占用'),
      subtitle: Text('$_text · 每 2 秒刷新，点击立即刷新'),
      onTap: _refresh,
    );
  }
}
