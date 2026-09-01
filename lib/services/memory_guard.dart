import 'dart:async';
import 'dart:io' show Platform, Process;

import 'package:flutter/foundation.dart' show ValueNotifier;

/// 系统内存压力哨兵（macOS / iOS）。
///
/// 背景：WKWebView 的图形表面高水位没有任何公开降水位 API，社区公认
/// 的解法就是销毁重建 WebView（WebContent 进程整体回收，见诊断悬浮窗
/// 的「释放内存并重连」）。本服务把这件事自动化：定时异步读取系统内存
/// 压力级别（sysctl kern.memorystatus_vm_pressure_level，1 正常 /
/// 2 警告 / 3 紧急 / 4 危急，macOS 26 实测存在且本进程可读），达到
/// 紧急级别才动手：
///
/// - 级别 ≥ 3：回收**非当前**会话（销毁 WebView，页签保留，点回来自动重建）
/// - 级别 ≥ 4：连**当前**会话一起重建（页面重载，提示已弹出）
///
/// 平时零感知（级别 1/2 不动作——实测本机常态就是 2，不能拿它当触发线）；
/// 同一确认窗口内动作只做一次，防止回收-重建循环。阈值与冷却期是常量，
/// 按 A/B 实测结果再调。
///
/// [pressureLevel] 把当前级别暴露给悬浮球角标展示（0 = 尚未读到），
/// 即使自动回收开关关着也照常更新——角标是纯信息展示。
class MemoryGuard {
  MemoryGuard._();

  static final MemoryGuard instance = MemoryGuard._();

  /// 触发回收的最低压力级别（3 = 紧急）。
  static const int _actLevel = 3;

  /// 同级别动作的最小间隔。
  static const Duration _cooldown = Duration(minutes: 10);

  /// 轮询间隔。
  static const Duration _interval = Duration(seconds: 10);

  /// 当前系统内存压力级别（0 = 尚未读到），悬浮球角标的数据源。
  final ValueNotifier<int> pressureLevel = ValueNotifier<int>(0);

  Timer? _timer;
  DateTime _lastAction = DateTime.fromMillisecondsSinceEpoch(0);

  // —— 宿主（HomePage）注入的委托 ——

  /// 自动回收开关是否开启（每 tick 实时询问；关闭只停动作，角标照常刷新）。
  bool Function()? enabledProvider;

  /// 当前打开的会话 id 列表。
  List<String> Function()? openIdsProvider;

  /// 当前显示中的会话 id。
  String? Function()? currentIdProvider;

  /// 执行回收：非当前会话挂起（销毁 WebView 留页签），当前会话重建。
  void Function(String id, {required bool isCurrent})? onReclaim;

  /// 面向用户的提示（SnackBar）。
  void Function(String message)? onNotify;

  bool get _supported => Platform.isMacOS || Platform.isIOS;

  void start() {
    if (!_supported || _timer != null) return;
    _timer = Timer.periodic(_interval, (_) => _check());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _check() async {
    final level = await _readPressureLevel();
    // 角标数据先更新：无论自动回收开不开，级别都实时可见。
    if (level != null) pressureLevel.value = level;
    if (enabledProvider?.call() != true) return;
    if (level == null || level < _actLevel) return;
    // 冷却期：压力会持续一段时间，反复回收-重建只会折腾页面。
    if (DateTime.now().difference(_lastAction) < _cooldown) return;

    final ids = openIdsProvider?.call() ?? const [];
    final current = currentIdProvider?.call();
    final targets = ids.where((id) => id != current).toList();
    if (ids.isEmpty) return;

    _lastAction = DateTime.now();
    if (level >= 4) {
      // 危急：全部回收，当前会话重建（页面重载）。
      for (final id in ids) {
        onReclaim?.call(id, isCurrent: id == current);
      }
      onNotify?.call('系统内存危急，已自动回收全部会话以释放内存');
    } else if (targets.isNotEmpty) {
      // 紧急：只回收后台会话（当前会话无感知）。
      for (final id in targets) {
        onReclaim?.call(id, isCurrent: false);
      }
      onNotify?.call('系统内存吃紧，已自动回收 ${targets.length} 个后台会话'
          '（页签保留，点击即恢复）');
    }
  }

  /// 读系统内存压力级别；键不存在或读取失败返回 null（哨兵自动哑火）。
  Future<int?> _readPressureLevel() async {
    try {
      final res = await Process.run('sysctl',
          ['-n', 'kern.memorystatus_vm_pressure_level']);
      if (res.exitCode != 0) return null;
      return int.tryParse((res.stdout as String).trim());
    } catch (_) {
      return null;
    }
  }
}
