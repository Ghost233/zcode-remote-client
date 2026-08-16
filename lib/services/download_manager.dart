import 'dart:async';
import 'dart:convert' show jsonDecode;
import 'dart:io' show Directory, File, Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'update_checker.dart';

/// 通知栏点按跳转用的全局导航键（main.dart 挂到 MaterialApp 上）。
final GlobalKey<NavigatorState> kAppNavigatorKey = GlobalKey<NavigatorState>();

enum DownloadStatus { idle, downloading, cancelled, failed, completed }

/// 本地已有的下载产物状态。
enum ExistingFileState { none, partial, completed }

/// 启动检查发现新版本后的处置方式。
enum StartupAction { askUser, autoResumed, readyToInstall, pausedByUser }

/// 后台更新下载管理器（Android）。
///
/// - 下载不绑定任何界面：进度弹窗关掉、切后台都继续，通知栏常驻进度；
/// - 断点自动续传：重启后启动检查发现断点即自动接着下（用户主动取消
///   过的除外，尊重意愿不强行恢复）；
/// - 完成包保留：安装失败/取消后再次「立即更新」直接重新拉起安装，
///   不再下载；
/// - 每次检查更新发现新版本，先删光旧版本的全部产物（整包/断点/meta）；
/// - 全部重试失败：设置页弹窗（继续重试 / 删除重下），其余场景只发
///   通知栏提醒。
class DownloadManager {
  DownloadManager._();

  static final DownloadManager instance = DownloadManager._();

  final status = ValueNotifier<DownloadStatus>(DownloadStatus.idle);
  final receivedBytes = ValueNotifier<int>(0);
  final totalBytes = ValueNotifier<int>(1);
  final retryText = ValueNotifier<String>('');

  /// 当前目标 release 与选中的 APK 资产（按设备 ABI）。
  AppRelease? release;
  ReleaseAsset? asset;

  /// 下载完成后的 APK 路径（安装复用；重启后由 existingFileState 恢复）。
  String? completedPath;

  /// 失败时的前台呈现者（优先级从高到低）：
  /// 1. 下载进度弹窗在显示 → 弹窗内联展示；
  /// 2. 设置页在显示 → 设置页弹窗；
  /// 3. 都没有 → 通知栏提醒。
  void Function()? foregroundFailurePresenter;
  void Function()? settingsFailurePresenter;

  /// 通知栏「去设置处理」入口（main.dart 注入，避免反向依赖页面层）。
  void Function()? onOpenSettings;

  bool _cancelFlag = false;
  Future<void>? _job;
  String? _jobAssetName;
  bool _interactiveJob = false;
  List<String> _abis = const [];
  FlutterLocalNotificationsPlugin? _notif;
  int _lastNotifiedPercent = -1;
  DateTime _lastNotifiedAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _retryTextAt = 0;

  /// 用户主动取消过的包名（重启后启动检查不再自动续传）。
  static const _cancelPrefKey = 'update_download_user_cancelled_asset';

  // ---------- 初始化 ----------

  Future<void> init() async {
    if (!Platform.isAndroid) return;
    final plugin = FlutterLocalNotificationsPlugin();
    _notif = plugin;
    try {
      await plugin.initialize(
        settings: InitializationSettings(
          android: AndroidInitializationSettings('ic_stat_download'),
        ),
        onDidReceiveNotificationResponse: (resp) =>
            _onNotificationTap(resp.payload),
      );
    } catch (_) {
      _notif = null;
      return;
    }
    // 冷启动由通知拉起：等首帧和首页就绪后再跳转。
    final details = await plugin.getNotificationAppLaunchDetails();
    final payload = details?.notificationResponse?.payload;
    if (payload != null && payload.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        _onNotificationTap(payload);
      });
    }
  }

  void _onNotificationTap(String? payload) {
    if (payload == null) return;
    if (payload.startsWith('install:')) {
      promptInstall();
    } else if (payload == 'settings') {
      onOpenSettings?.call();
    }
  }

  // ---------- 状态查询与清理 ----------

  Future<List<String>> get abis async {
    if (_abis.isNotEmpty) return _abis;
    try {
      _abis = (await DeviceInfoPlugin().androidInfo).supportedAbis;
    } catch (_) {}
    return _abis;
  }

  Future<Directory> _downloadsDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/downloads');
    await dir.create(recursive: true);
    return dir;
  }

  /// 查询某 release 的本地产物状态。每次调用都会先清掉**其他版本**的
  /// 全部残留（整包、断点分片、meta），完成包校验不过也一并作废。
  Future<ExistingFileState> existingFileState(AppRelease rel) async {
    if (!Platform.isAndroid) return ExistingFileState.none;
    final picked = rel.androidApkFor(await abis);
    if (picked == null) return ExistingFileState.none;
    final dir = await _downloadsDir();
    await _cleanupOtherVersions(dir, picked.name);

    final target = File('${dir.path}/${picked.name}');
    final marker = File('${dir.path}/${picked.name}.done');
    if (await marker.exists() && await target.exists()) {
      final expect = int.tryParse((await marker.readAsString()).trim());
      if (expect != null && await target.length() == expect) {
        release = rel;
        asset = picked;
        completedPath = target.path;
        if (status.value != DownloadStatus.downloading) {
          status.value = DownloadStatus.completed;
        }
        return ExistingFileState.completed;
      }
      await _deleteFor(dir, picked.name); // 完成包损坏：作废重下
      return ExistingFileState.none;
    }
    // 残缺整包（拼装中途被打断）：作废，靠分片/meta 重新拼。
    if (await target.exists()) {
      try {
        await target.delete();
      } catch (_) {}
    }
    try {
      for (final e in dir.listSync()) {
        final n = e.uri.pathSegments.last;
        if (n.startsWith('${picked.name}.part') || n == '${picked.name}.meta') {
          release = rel;
          asset = picked;
          await _restoreProgressFromParts(dir, picked.name);
          return ExistingFileState.partial;
        }
      }
    } catch (_) {}
    return ExistingFileState.none;
  }

  /// 有断点但没在下载（重启后）：从 meta + 分片长度恢复进度显示。
  Future<void> _restoreProgressFromParts(Directory dir, String name) async {
    try {
      final meta = File('${dir.path}/$name.meta');
      if (!await meta.exists()) return;
      final m = jsonDecode(await meta.readAsString());
      if (m is! Map || m['total'] is! int) return;
      var got = 0;
      for (var i = 0;; i++) {
        final f = File('${dir.path}/$name.part$i');
        if (!await f.exists()) break;
        got += await f.length();
      }
      totalBytes.value = m['total'] as int;
      receivedBytes.value = got;
    } catch (_) {}
  }

  /// 已是最新版本（没有更新可下）时清空整个下载目录。
  Future<void> purgeAll() async {
    if (!Platform.isAndroid) return;
    if (status.value == DownloadStatus.downloading) return;
    try {
      final dir = await _downloadsDir();
      for (final e in dir.listSync()) {
        try {
          await e.delete(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}
    status.value = DownloadStatus.idle;
    completedPath = null;
  }

  /// 启动静默检查发现新版本时的处置。
  Future<StartupAction> onStartupCheck(AppRelease rel) async {
    final state = await existingFileState(rel);
    switch (state) {
      case ExistingFileState.completed:
        _notifyReady(); // 已下载未安装：通知栏提醒，点按即装
        return StartupAction.readyToInstall;
      case ExistingFileState.partial:
        if (asset != null && await _userCancelled(asset!.name)) {
          // 用户上次主动取消：启动不强拉，设置页可见「已暂停·继续下载」。
          status.value = DownloadStatus.cancelled;
          return StartupAction.pausedByUser;
        }
        await start(rel); // 后台自动续传 + 通知栏进度
        return StartupAction.autoResumed;
      case ExistingFileState.none:
        return StartupAction.askUser;
    }
  }

  // ---------- 下载控制 ----------

  /// 开始（或从断点继续）下载。已下载完成时直接进入安装流程，
  /// [interactive] 为 true 表示用户正在更新流程里（完成后自动拉起安装，
  /// 否则只发「点击安装」通知）。
  Future<void> start(AppRelease rel, {bool interactive = false}) async {
    if (!Platform.isAndroid) {
      await launchUrl(
        Uri.parse(rel.htmlUrl),
        mode: LaunchMode.externalApplication,
      );
      return;
    }
    final picked = rel.androidApkFor(await abis);
    if (picked == null) {
      await launchUrl(
        Uri.parse(rel.htmlUrl),
        mode: LaunchMode.externalApplication,
      );
      return;
    }
    final dir = await _downloadsDir();
    await _cleanupOtherVersions(dir, picked.name);
    release = rel;
    asset = picked;

    // 完成包还在：安装失败/取消后再次更新直接拉安装（不用重下）。
    final target = File('${dir.path}/${picked.name}');
    final marker = File('${dir.path}/${picked.name}.done');
    if (await marker.exists() && await target.exists()) {
      final expect = int.tryParse((await marker.readAsString()).trim());
      if (expect != null && await target.length() == expect) {
        completedPath = target.path;
        status.value = DownloadStatus.completed;
        if (interactive) {
          await promptInstall();
        } else {
          _notifyReady();
        }
        return;
      }
      await _deleteFor(dir, picked.name);
    }

    // 同一个包已在下载：撤销可能的取消标记，从断点继续即可。
    if (_job != null && _jobAssetName == picked.name) {
      _cancelFlag = false;
      await _clearCancelPref(picked.name);
      status.value = DownloadStatus.downloading;
      return;
    }
    // 换了目标包（理论上少见）：先停掉旧任务。
    if (_job != null) {
      _cancelFlag = true;
      try {
        await _job;
      } catch (_) {}
    }

    await _requestNotifPermission();
    _cancelFlag = false;
    _interactiveJob = interactive;
    _jobAssetName = picked.name;
    completedPath = null;
    await _clearCancelPref(picked.name);
    retryText.value = '';
    receivedBytes.value = 0;
    totalBytes.value = 1;
    status.value = DownloadStatus.downloading;
    _lastNotifiedPercent = -1;
    final job = _run();
    _job = job;
    unawaited(
      job.whenComplete(() {
        if (identical(_job, job)) _job = null;
      }),
    );
  }

  Future<void> _run() async {
    final rel = release;
    final a = asset;
    if (rel == null || a == null) return;
    try {
      final path = await UpdateChecker.downloadAndroidApk(
        rel,
        (r, t) {
          receivedBytes.value = r;
          totalBytes.value = t > 0 ? t : 1;
          // 重试提示只在网络恢复推进 2MB 后自动消失，期间保留说明。
          if (retryText.value.isNotEmpty &&
              r - _retryTextAt > 2 * 1024 * 1024) {
            retryText.value = '';
          }
          _notifyProgress();
        },
        abis: _abis,
        shouldCancel: () => _cancelFlag,
        onRetry: (attempt) {
          _retryTextAt = receivedBytes.value;
          retryText.value = '网络中断，断点续传中（第 $attempt 次）…';
        },
        onRestart: () {
          _retryTextAt = receivedBytes.value;
          retryText.value = '下载源校验不一致，正在从头重新下载…';
        },
      );
      if (path == null) {
        _onFailed();
        return;
      }
      final len = await File(path).length();
      try {
        await File('$path.done').writeAsString('$len');
      } catch (_) {}
      completedPath = path;
      status.value = DownloadStatus.completed;
      _cancelProgressNotification();
      _notifyReady();
      if (_interactiveJob) await promptInstall();
    } on UpdateDownloadCancelled {
      status.value = DownloadStatus.cancelled;
      _setCancelPref(a.name);
      _cancelProgressNotification();
    } catch (_) {
      _onFailed();
    }
  }

  void _onFailed() {
    status.value = DownloadStatus.failed;
    if (foregroundFailurePresenter != null) {
      foregroundFailurePresenter!();
    } else if (settingsFailurePresenter != null) {
      settingsFailurePresenter!();
    } else {
      _notifyFailed();
    }
  }

  /// 用户主动取消：保留断点供下次续传；记下标记，重启后的自动检查
  /// 不会强行恢复，只有手动「继续下载」才清标记。
  void cancel() {
    if (status.value != DownloadStatus.downloading) return;
    _cancelFlag = true;
    status.value = DownloadStatus.cancelled;
    _cancelProgressNotification();
  }

  /// 从断点继续重试（失败/取消后）。
  Future<void> retry({bool interactive = false}) async {
    final rel = release;
    if (rel == null || status.value == DownloadStatus.downloading) return;
    await start(rel, interactive: interactive);
  }

  /// 删除本包全部产物（含断点）后重新下载。
  Future<void> deleteAndRestart({bool interactive = false}) async {
    final rel = release;
    if (rel == null) return;
    final a = asset;
    if (a != null) {
      await _deleteFor(await _downloadsDir(), a.name);
    }
    completedPath = null;
    status.value = DownloadStatus.idle;
    await start(rel, interactive: interactive);
  }

  /// 拉起安装；失败（常见为未授权「安装未知应用」）兜底打开发布页。
  Future<void> promptInstall() async {
    final path = completedPath;
    final rel = release;
    if (path == null || rel == null) return;
    try {
      final res = await OpenFilex.open(path);
      if (res.type != ResultType.done) {
        await launchUrl(
          Uri.parse(rel.htmlUrl),
          mode: LaunchMode.externalApplication,
        );
      }
    } catch (_) {
      await launchUrl(
        Uri.parse(rel.htmlUrl),
        mode: LaunchMode.externalApplication,
      );
    }
  }

  // ---------- 本地文件操作 ----------

  /// 删除 downloads 目录里所有不属于 [keep] 资产的文件（旧版本残留）。
  Future<void> _cleanupOtherVersions(Directory dir, String keep) async {
    try {
      for (final e in dir.listSync()) {
        if (e.uri.pathSegments.last.startsWith(keep)) continue;
        try {
          await e.delete(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 删除某资产的全部产物：整包、done 标记、断点分片、meta。
  Future<void> _deleteFor(Directory dir, String name) async {
    try {
      for (final e in dir.listSync()) {
        final n = e.uri.pathSegments.last;
        if (n == name || n.startsWith('$name.')) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  Future<void> _setCancelPref(String assetName) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_cancelPrefKey, assetName);
    } catch (_) {}
  }

  Future<void> _clearCancelPref(String assetName) async {
    try {
      final p = await SharedPreferences.getInstance();
      if (p.getString(_cancelPrefKey) == assetName) {
        await p.remove(_cancelPrefKey);
      }
    } catch (_) {}
  }

  Future<bool> _userCancelled(String assetName) async {
    try {
      final p = await SharedPreferences.getInstance();
      return p.getString(_cancelPrefKey) == assetName;
    } catch (_) {
      return false;
    }
  }

  // ---------- 通知栏 ----------

  Future<void> _requestNotifPermission() async {
    try {
      await _notif
          ?.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
    } catch (_) {}
  }

  /// 进度通知：按百分比变化节流（同一百分比最多 1.5s 刷一次文案）。
  void _notifyProgress() {
    final plugin = _notif;
    if (plugin == null) return;
    final total = totalBytes.value;
    // 总大小未知（探测失败兜底）时不能用假百分比——那会瞬间"走满"。
    final sizeKnown = total > 1;
    final pct = sizeKnown ? receivedBytes.value * 100 ~/ total : 0;
    final now = DateTime.now();
    if (pct == _lastNotifiedPercent &&
        now.difference(_lastNotifiedAt).inMilliseconds < 1500) {
      return;
    }
    _lastNotifiedPercent = pct;
    _lastNotifiedAt = now;
    try {
      plugin.show(
        id: _progressNotifId,
        title: '正在下载 v${release?.version ?? ''}',
        body: sizeKnown
            ? '${(receivedBytes.value / 1048576).toStringAsFixed(1)} / '
                  '${(total / 1048576).toStringAsFixed(1)} MB（$pct%）'
            : '大小未知，已下载 '
                  '${(receivedBytes.value / 1048576).toStringAsFixed(1)} MB',
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            'update_progress',
            '更新下载',
            channelDescription: '应用更新包下载进度',
            icon: 'ic_stat_download',
            importance: Importance.low,
            priority: Priority.low,
            ongoing: true,
            onlyAlertOnce: true,
            silent: true,
            autoCancel: false,
            showProgress: true,
            // maxProgress 0 + progress 0 = 系统的不定态进度条。
            maxProgress: sizeKnown ? 100 : 0,
            progress: sizeKnown ? pct : 0,
          ),
        ),
      );
    } catch (_) {}
  }

  void _notifyReady() {
    try {
      _notif?.show(
        id: _resultNotifId,
        title: 'v${release?.version ?? ''} 已下载完成',
        body: '点击安装更新',
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            'update_result',
            '更新提醒',
            channelDescription: '更新下载完成或失败的提醒',
            icon: 'ic_stat_download',
            importance: Importance.high,
            priority: Priority.high,
            autoCancel: true,
          ),
        ),
        payload: 'install:$completedPath',
      );
    } catch (_) {}
  }

  void _notifyFailed() {
    try {
      _notif?.show(
        id: _resultNotifId,
        title: '更新下载失败',
        body: '网络不佳，自动重试多次仍未成功。点开继续重试或删除重下',
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            'update_result',
            '更新提醒',
            channelDescription: '更新下载完成或失败的提醒',
            icon: 'ic_stat_download',
            importance: Importance.high,
            priority: Priority.high,
            autoCancel: true,
          ),
        ),
        payload: 'settings',
      );
    } catch (_) {}
  }

  void _cancelProgressNotification() {
    try {
      _notif?.cancel(id: _progressNotifId);
    } catch (_) {}
  }

  static const _progressNotifId = 1001;
  static const _resultNotifId = 1002;
}
