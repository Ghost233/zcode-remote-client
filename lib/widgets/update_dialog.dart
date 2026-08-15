import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/update_checker.dart';

/// 检查更新入口：启动时静默检查（manual=false，失败/无更新不打扰），
/// 设置页手动检查（manual=true，结果都有提示）。
Future<void> checkForUpdates(
  BuildContext context, {
  bool manual = false,
}) async {
  final info = await PackageInfo.fromPlatform();
  final release = await UpdateChecker.fetchLatest();
  if (!context.mounted) return;

  if (release == null) {
    if (manual) _toast(context, '检查更新失败，请稍后重试');
    return;
  }
  if (!UpdateChecker.isNewer(release.version, info.version)) {
    if (manual) _toast(context, '已是最新版本 v${info.version}');
    return;
  }

  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('发现新版本 v${release.version}'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Text(
            release.notes.isEmpty ? '详见发布页面' : release.notes,
            style: const TextStyle(fontSize: 13, height: 1.5),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('稍后'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('立即更新'),
        ),
      ],
    ),
  );
  if (go != true || !context.mounted) return;

  if (Platform.isAndroid) {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ApkDownloadDialog(release: release),
    );
  } else {
    // iOS/macOS/Windows：自更新需要签名/分发体系，直接打开发布页。
    await launchUrl(
      Uri.parse(release.htmlUrl),
      mode: LaunchMode.externalApplication,
    );
  }
}

void _toast(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(msg)));
}

/// Android 应用内下载 APK 并拉起安装；拉不起安装器（未授予
/// "安装未知应用"权限）时兜底打开发布页。
class _ApkDownloadDialog extends StatefulWidget {
  const _ApkDownloadDialog({required this.release});

  final AppRelease release;

  @override
  State<_ApkDownloadDialog> createState() => _ApkDownloadDialogState();
}

class _ApkDownloadDialogState extends State<_ApkDownloadDialog> {
  int _received = 0;
  int _total = 1;
  String? _error;
  bool _cancelRequested = false;
  String _retryStatus = '';

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      // 按设备实际支持的 CPU 架构挑对应 APK（发布页挂多架构包）。
      var abis = const <String>[];
      try {
        final info = await DeviceInfoPlugin().androidInfo;
        abis = info.supportedAbis;
      } catch (_) {}
      final path = await UpdateChecker.downloadAndroidApk(
        widget.release,
        (received, total) {
          if (mounted) {
            setState(() {
              _received = received;
              _total = total > 0 ? total : 1;
            });
          }
        },
        abis: abis,
        shouldCancel: () => _cancelRequested,
        onRetry: (attempt) {
          if (mounted) {
            setState(() => _retryStatus = '网络中断，断点续传中（第 $attempt 次）…');
          }
        },
      );
      if (path == null) throw StateError('下载失败');
      if (!mounted) return;
      Navigator.of(context).pop();
      final res = await OpenFilex.open(path);
      if (res.type != ResultType.done) {
        // 常见于未允许"安装未知应用"：引导去发布页手动下载安装。
        await launchUrl(
          Uri.parse(widget.release.htmlUrl),
          mode: LaunchMode.externalApplication,
        );
      }
    } on UpdateDownloadCancelled {
      // 用户取消：静默退出，已下载部分保留供下次续传。
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) setState(() => _error = '下载失败，可到发布页手动下载');
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = (_received / _total).clamp(0.0, 1.0);
    return AlertDialog(
      title: Text(_error == null ? '正在下载更新' : '下载失败'),
      content: _error == null
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: progress >= 1 ? null : progress),
                const SizedBox(height: 10),
                Text(
                  '${(_received / 1048576).toStringAsFixed(1)} / '
                  '${(_total / 1048576).toStringAsFixed(1)} MB',
                  style: const TextStyle(fontSize: 12),
                ),
                if (_retryStatus.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    _cancelRequested ? '正在取消…' : _retryStatus,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                ],
              ],
            )
          : Text(_error!),
      actions: [
        if (_error != null)
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          )
        else if (!_cancelRequested)
          TextButton(
            onPressed: () => setState(() => _cancelRequested = true),
            child: const Text('取消'),
          ),
      ],
    );
  }
}
