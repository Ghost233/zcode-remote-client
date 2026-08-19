import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Android 后台保活：退后台时挂前台服务（常驻通知），回前台撤掉。
///
/// 没有它，应用退后台后系统会冻结网络（Doze）/可能回收进程，ZCode 页面
/// 的 WebSocket 断开，回到前台页面就整页刷新重连。前台服务让进程和网络
/// 在后台不受限。iOS 系统不允许第三方后台保活，此封装为空操作。
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
}
