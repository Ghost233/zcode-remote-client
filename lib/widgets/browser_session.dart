import 'package:flutter/widgets.dart';

/// 浏览器会话视图的公共接口。
///
/// 两份实现：BrowserView（iOS/Android/Windows，flutter_inappwebview）
/// 与 CefBrowserView（macOS，webview_cef/Chromium）。悬浮工具栏和首页
/// 通过 [sessionOf] 使用，不关心底层 WebView 是哪家。
abstract class BrowserSession {
  /// 平移（抓手）模式开关。
  ValueNotifier<bool> get panMode;

  /// 双指缩放开关（仅 Android 实际生效；macOS 置灰）。
  ValueNotifier<bool> get pinchZoom;

  Future<void> setPanMode(bool enabled);

  Future<void> setPinchZoom(bool enabled);

  Future<bool> canGoBack();

  Future<void> goBack();

  Future<bool> canGoForward();

  Future<void> goForward();

  Future<void> reload();

  Future<String?> currentUrl();

  Future<void> copyPageLink();

  Future<void> sharePage();

  Future<void> copyAllText();

  Future<void> openExternal();
}

/// 从 GlobalKey 安全取会话接口；视图未挂载/尚未创建时返回 null。
///
/// 显式走 dynamic：BrowserSession 与 State 没有父子关系，`is` 检查
/// 无法做类型提升，直接写三元会有编译错误。
BrowserSession? sessionOf(GlobalKey? key) {
  final dynamic state = key?.currentState;
  return state is BrowserSession ? state : null;
}
