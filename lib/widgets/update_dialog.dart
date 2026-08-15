import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/download_manager.dart';
import '../services/update_checker.dart';

/// 检查更新入口：
/// - 启动静默检查（manual=false）：不打扰——断点自动续传/已就绪只走
///   通知栏，用户主动取消过的不强拉，其余情况才弹「发现新版本」；
/// - 手动检查（manual=true，设置页/悬浮球）：结果都有提示，发现新版本
///   一律弹窗，点「立即更新」后按本地产物状态自动决定续传/直接安装。
Future<void> checkForUpdates(
  BuildContext context, {
  bool manual = false,
}) async {
  final info = await PackageInfo.fromPlatform();
  final release = await UpdateChecker.fetchLatest();
  if (!context.mounted) return;

  final dm = DownloadManager.instance;

  if (release == null) {
    if (manual) _toast(context, '检查更新失败，请稍后重试');
    return;
  }
  if (!UpdateChecker.isNewer(release.version, info.version)) {
    if (manual) _toast(context, '已是最新版本 v${info.version}');
    // 已是最新：本地残留（上个版本的整包/断点）全部清掉。
    await dm.purgeAll();
    return;
  }

  if (!manual && Platform.isAndroid) {
    // 启动静默检查交给下载管理器处置：自动续传 / 已就绪通知 /
    // 用户暂停，都不弹窗；只有全新版本才走下面的引导弹窗。
    final action = await dm.onStartupCheck(release);
    switch (action) {
      case StartupAction.askUser:
        break;
      case StartupAction.autoResumed:
      case StartupAction.readyToInstall:
      case StartupAction.pausedByUser:
        return;
    }
  } else if (Platform.isAndroid) {
    // 手动检查：先清旧版本残留并刷新本地产物状态。
    await dm.existingFileState(release);
  }
  if (!context.mounted) return;

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
    // 已有完成包时 start() 会直接拉起安装；否则开始/续传下载并弹进度。
    await dm.start(release, interactive: true);
    if (dm.status.value == DownloadStatus.downloading && context.mounted) {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const _ApkDownloadDialog(),
      );
    }
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

/// 下载进度弹窗：DownloadManager 的纯观察者。
///
/// 关掉弹窗（后台继续）不会中断下载——下载在后台继续，通知栏有进度；
/// 「取消下载」保留断点，下次可从断点继续；全部重试失败时在弹窗内
/// 提供「删除重下 / 继续重试」。
class _ApkDownloadDialog extends StatefulWidget {
  const _ApkDownloadDialog();

  @override
  State<_ApkDownloadDialog> createState() => _ApkDownloadDialogState();
}

class _ApkDownloadDialogState extends State<_ApkDownloadDialog> {
  bool _error = false;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    final dm = DownloadManager.instance;
    dm.foregroundFailurePresenter = _presentFailure;
    dm.status.addListener(_onStatus);
  }

  @override
  void dispose() {
    final dm = DownloadManager.instance;
    dm.status.removeListener(_onStatus);
    if (dm.foregroundFailurePresenter == _presentFailure) {
      dm.foregroundFailurePresenter = null;
    }
    super.dispose();
  }

  void _presentFailure() {
    if (mounted) setState(() => _error = true);
  }

  void _onStatus() {
    if (!mounted || _closed) return;
    switch (DownloadManager.instance.status.value) {
      case DownloadStatus.completed:
      case DownloadStatus.cancelled:
        _close();
        break;
      case DownloadStatus.failed:
        _presentFailure();
        break;
      default:
        break;
    }
  }

  void _close() {
    if (_closed || !mounted) return;
    _closed = true;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final dm = DownloadManager.instance;
    return AlertDialog(
      title: Text(_error ? '下载失败' : '正在下载更新'),
      content: _error
          ? const Text(
              '网络不佳，自动重试多次仍未成功。\n'
              '可从断点继续重试，或删除后重新下载。',
              style: TextStyle(fontSize: 13, height: 1.5),
            )
          : ListenableBuilder(
              listenable: Listenable.merge([
                dm.receivedBytes,
                dm.totalBytes,
                dm.retryText,
                dm.status,
              ]),
              builder: (context, _) {
                final received = dm.receivedBytes.value;
                final total = dm.totalBytes.value;
                final progress =
                    total > 0 ? (received / total).clamp(0.0, 1.0) : 0.0;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LinearProgressIndicator(
                      value: progress >= 1 ? null : progress,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '${(received / 1048576).toStringAsFixed(1)} / '
                      '${(total / 1048576).toStringAsFixed(1)} MB',
                      style: const TextStyle(fontSize: 12),
                    ),
                    if (dm.retryText.value.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        dm.retryText.value,
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).hintColor,
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      '关掉本窗口也会在后台继续下载（通知栏可见进度）',
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).hintColor,
                      ),
                    ),
                  ],
                );
              },
            ),
      actions: [
        if (_error) ...[
          TextButton(
            onPressed: _close,
            child: const Text('稍后'),
          ),
          OutlinedButton(
            onPressed: () {
              setState(() => _error = false);
              dm.deleteAndRestart(interactive: true);
            },
            child: const Text('删除重新下载'),
          ),
          FilledButton(
            onPressed: () {
              setState(() => _error = false);
              dm.retry(interactive: true);
            },
            child: const Text('继续重试'),
          ),
        ] else ...[
          TextButton(
            onPressed: () {
              DownloadManager.instance.cancel();
              _close();
            },
            child: const Text('取消下载'),
          ),
          FilledButton(
            onPressed: _close,
            child: const Text('后台继续'),
          ),
        ],
      ],
    );
  }
}
