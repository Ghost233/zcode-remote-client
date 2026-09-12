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
class BackgroundKeepAlive {
  BackgroundKeepAlive._();

  static const _channel = MethodChannel('app/keep_alive');
  static bool _running = false;

  /// [text]：常驻通知文案。用途不同文案不同（保活会话/后台下载），
  /// 默认保持会话连接。已运行时重复调用不早退——原生 startService 重发
  /// intent 只会刷新通知文案，需要靠它把「后台下载」文案换回会话文案。
  static Future<void> start({String text = '正在后台保持会话连接'}) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('start', {'text': text});
      _running = true;
    } catch (_) {
      _running = false;
    }
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid || !_running) return;
    _running = false;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}
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

  /// 把全部 WebView 的渲染进程优先级钉为「与应用同级、后台不豁免」。
  ///
  /// 前台服务只保住主进程与网络；WebSocket 实际活在 WebView 独立的
  /// 渲染进程里——应用退后台后它被系统降级，Android 11+ 的缓存进程
  /// 冻结器会整个冻住它（定时器与套接字 I/O 全停），内存紧张时还会
  /// 被单独回收，回前台页面就断连重连、整屏刷新。钉住后渲染进程随
  /// 主进程同生共死。对 WebView 实例持久生效，重复调用无副作用；
  /// 原生侧自带特性门控（老旧系统 WebView 不支持时静默跳过）。
  static Future<void> pinWebViewRenderers() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('pinRenderers');
    } catch (_) {}
  }
}
