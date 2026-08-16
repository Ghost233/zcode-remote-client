import 'package:flutter/widgets.dart';

/// 浏览器会话视图的公共接口。
///
/// 当前唯一实现：BrowserView（flutter_inappwebview，全平台）。悬浮工具栏
/// 和首页通过 [sessionOf] 使用这个接口而非具体类型，将来若再换承载
/// （如 macOS 曾短暂用过的 CEF）不必改动调用方。
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
