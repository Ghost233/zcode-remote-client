import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Android 后台保活：退后台时挂前台服务（常驻通知），回前台撤掉。
///
/// 没有它，应用退后台后系统会冻结网络（Doze）/可能回收进程，ZCode 页面
/// 的 WebSocket 断开，回到前台页面就整页刷新重连。前台服务让进程和网络
/// 在后台不受限。iOS 系统不允许第三方后台保活，此封装为空操作。
///
/// 挂服务有两个路径：原生 MainActivity.onPause 直接挂（主路径，onPause
/// 是 Android 12+ 后台启动限制生效前最后的成功时机，开关状态经
/// [syncEnabled] 同步到原生持久化）；Dart 生命周期回调补挂（修正通知
/// 文案 + 兜底）。
///
/// 除启停外还承载两件事：
/// - 渲染进程优先级钉扎（[pinWebViewRenderers]）；
/// - 系统内存吃紧事件转发（[setOnTrimMemory]，原生 onTrimMemory →
///   Dart 主动挂起后台会话，抢在系统整组杀进程之前自己优雅回收）。
class BackgroundKeepAlive {
  BackgroundKeepAlive._();

  static const _channel = MethodChannel('app/keep_alive');
  static Timer? _stopTimer;

  static void Function(int level)? _onTrimMemory;

  /// [text]：常驻通知文案。用途不同文案不同（保活会话/后台下载），
  /// 默认保持会话连接。已运行时重复调用不早退——原生 startService 重发
  /// intent 只会刷新通知文案，需要靠它把「后台下载」文案换回会话文案。
  /// 同时取消待执行的延迟撤除（快速后台→前台→后台时服务不闪撤）。
  static Future<void> start({String text = '正在后台保持会话连接'}) async {
    if (!Platform.isAndroid) return;
    _stopTimer?.cancel();
    _stopTimer = null;
    try {
      await _channel.invokeMethod<void>('start', {'text': text});
    } catch (_) {}
  }

  /// 撤服务**延迟 3 秒**执行。
  ///
  /// 不能立刻撤：onPause 挂的前台服务可能还没走到 onStartCommand 里的
  /// startForeground，此瞬间 stopService 会把「待挂前台」的服务直接拉
  /// 停，系统按「startForegroundService 后未调用 startForeground」判
  /// 应用违规、直接崩进程（快速后台→前台切换可复现窗口期）。延迟几秒
  /// 等服务挂稳再撤；期间重新 [start] 会取消本次撤除，快速切换场景下
  /// 服务连挂都不摘。撤一个没在跑的服务是无害空操作，所以原生侧单独
  /// 挂的服务（Dart 没经手）也能被这里撤掉，不漏。
  static Future<void> stop() {
    if (!Platform.isAndroid) return Future.value();
    _stopTimer?.cancel();
    _stopTimer = Timer(const Duration(seconds: 3), () async {
      _stopTimer = null;
      try {
        await _channel.invokeMethod<void>('stop');
      } catch (_) {}
    });
    return Future.value();
  }

  /// 把开关状态同步给原生侧持久化：原生 MainActivity.onPause 不经过
  /// Dart 直接决定要不要挂服务，需要自己持有开关（进程重启后原生
  /// 读自己的 SharedPreferences，不依赖 Dart 是否已加载）。
  static Future<void> syncEnabled(bool enabled) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('setEnabled', {'enabled': enabled});
    } catch (_) {}
  }

  /// 把全部 WebView 的渲染进程优先级钉为「NORMAL、后台不豁免」。
  ///
  /// 前台服务只保住主进程与网络；WebSocket 实际活在 WebView 独立的
  /// 渲染进程里——默认策略下退后台它被降到 WAIVED（等于 cached），
  /// Android 11+ 的缓存进程冻结器会整个冻住它（定时器与套接字 I/O
  /// 全停），回前台页面就断连重连、整屏刷新。NORMAL 钉在冻结线之上，
  /// 后台连接存活。
  ///
  /// 不用 IMPORTANT（v1.6.9 的教训）：它把渲染进程钉成「前台级不可
  /// 杀」，多会话时系统内存紧张杀不动这块内存，最终只能把整个应用
  /// 进程组连根杀（后台闪退）。NORMAL 让系统极端压力下可以「只回收
  /// 单个渲染进程」软着陆，会话由 Dart 侧挂起、回前台再重建。
  /// 对 WebView 实例持久生效，重复调用无副作用；原生侧自带特性门控
  /// （老旧系统 WebView 不支持时静默跳过）。
  static Future<void> pinWebViewRenderers() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('pinRenderers');
    } catch (_) {}
  }

  /// 注册/注销系统内存吃紧回调（原生 onTrimMemory 转发，仅 Android）。
  ///
  /// 原生侧只在真正的内存压力级别（RUNNING_LOW 以上、排除退后台常规
  /// 的 UI_HIDDEN）回调；宿主收到后应主动挂起不可见会话，抢在系统
  /// 整组杀进程之前把内存还回去。传 null 注销（同时摘掉通道接收器）。
  static void setOnTrimMemory(void Function(int level)? callback) {
    if (!Platform.isAndroid) return;
    _onTrimMemory = callback;
    _channel.setMethodCallHandler(
      callback == null
          ? null
          : (call) async {
              if (call.method == 'onTrimMemory') {
                _onTrimMemory?.call((call.arguments as num?)?.toInt() ?? 0);
              }
            },
    );
  }
}
