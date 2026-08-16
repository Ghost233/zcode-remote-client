import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_cef/webview_cef.dart';

import '../models/remote_device.dart';
import 'browser_session.dart';
import 'web_scripts.dart';

/// CEF（Chromium）浏览器视图，仅 macOS。
///
/// 取代内嵌 WKWebView：macOS 的 Flutter 平台视图层会破坏 WKWebView 的
/// 中文输入法组合态（Safari/Chrome 正常、仅内嵌坏；插件 #2380 认定为
/// Flutter 引擎级问题）。CEF 自带原生 IME 管线（上游以中文输入法实测），
/// 画面走 Flutter Texture 合成，不经过平台视图的键盘/焦点路由。
///
/// 与 BrowserView 的能力差异（macOS 可接受）：
/// - JS 弹窗、右键菜单交给 Chromium 默认行为；
/// - 页内下载 / window.open 无桥接（ZCode 远程终端用不到）；
/// - 无加载进度事件，顶部进度条为开始→结束之间的流动动画；
/// - 页面缩放走根节点 CSS zoom（桌面 Chromium 重排正确，与 Windows 同法）。
class CefBrowserView extends StatefulWidget {
  const CefBrowserView({
    super.key,
    required this.device,
    required this.pageZoom,
    required this.onSessionReady,
    required this.onTitleChanged,
    required this.onReplaceAddress,
  });

  final RemoteDevice device;

  /// 页面缩放（1.0 = 100%）：CSS zoom，桌面 Chromium 下等效浏览器 Ctrl +/-。
  final ValueNotifier<double> pageZoom;

  /// 会话就绪（等价 BrowserView 的 onControllerReady，用于通知工具栏刷新）。
  final VoidCallback onSessionReady;

  final void Function(String title) onTitleChanged;

  /// 加载失败时用户点了"替换地址"。
  final VoidCallback onReplaceAddress;

  @override
  State<CefBrowserView> createState() => CefBrowserViewState();
}

/// WebviewManager.initialize() 非幂等（会重置内部 Completer），全 App
/// 只能调一次——首个 CEF 会话发起，后续会话等同一个 Future。
Future<void>? _cefReadyFuture;

class CefBrowserViewState extends State<CefBrowserView>
    with AutomaticKeepAliveClientMixin
    implements BrowserSession {
  WebViewController? _controller;
  String? _url;
  bool _loading = false;

  @override
  final ValueNotifier<bool> panMode = ValueNotifier(false);

  /// macOS 无双指缩放（工具栏按钮置灰），保留接口空实现。
  @override
  final ValueNotifier<bool> pinchZoom = ValueNotifier(false);

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    widget.pageZoom.addListener(_applyPageZoom);
    _init();
  }

  Future<void> _init() async {
    debugPrint('[cef] 会话初始化开始: ${widget.device.url}');
    try {
      _cefReadyFuture ??= WebviewManager().initialize();
      await _cefReadyFuture;
      debugPrint('[cef] CEF 引擎就绪');
    } catch (e) {
      debugPrint('[cef] CEF 引擎初始化失败: $e');
      _cefReadyFuture = null; // 失败不缓存，下次创建会话可重试
      return; // CEF 初始化失败：停留加载态，用户可换系统浏览器。
    }
    if (!mounted) return;
    final c = WebviewManager().createWebView(
      loading: const Center(
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
    c.setWebviewListener(
      WebviewEventsListener(
        onTitleChanged: widget.onTitleChanged,
        onUrlChanged: (url) => _url = url,
        onLoadStart: (controller, url) {
          _url = url;
          if (mounted) setState(() => _loading = true);
        },
        onLoadEnd: (controller, url) async {
          _url = url;
          if (mounted) setState(() => _loading = false);
          await _applyPageZoom();
          // 新文档会清掉注入的拖拽层，平移模式开着的话重新注入。
          if (panMode.value) await _injectPanLayer();
        },
      ),
    );
    _controller = c;
    try {
      await c.initialize(widget.device.url);
    } catch (e) {
      debugPrint('[cef] 浏览器创建失败: $e');
      return;
    }
    debugPrint('[cef] 浏览器已创建');
    if (!mounted) return;
    setState(() {});
    widget.onSessionReady();
  }

  @override
  void dispose() {
    widget.pageZoom.removeListener(_applyPageZoom);
    panMode.dispose();
    pinchZoom.dispose();
    _controller?.dispose();
    super.dispose();
  }

  // ---------- 缩放 / 平移 ----------

  Future<void> _applyPageZoom() async {
    final c = _controller;
    if (c == null) return;
    await c.executeJavaScript(kPageZoomScript(widget.pageZoom.value));
  }

  Future<void> _injectPanLayer() async {
    await _controller?.executeJavaScript(kPanLayerScript);
  }

  @override
  Future<void> setPanMode(bool enabled) async {
    panMode.value = enabled;
    final c = _controller;
    if (c == null) return;
    if (enabled) {
      await c.executeJavaScript(kPanLayerScript);
    } else {
      await c.executeJavaScript(kPanCleanupScript);
    }
  }

  @override
  Future<void> setPinchZoom(bool enabled) async {
    // macOS 无双指缩放，空实现。
    pinchZoom.value = false;
  }

  // ---------- 会话接口 ----------

  bool _didGoBack = false;

  @override
  Future<bool> canGoBack() async {
    final c = _controller;
    if (c == null) return false;
    // CEF 没有暴露 canGoBack 查询，用 history.length 近似（首个导航后即可后退）。
    final r = await c.evaluateJavascript('history.length > 1');
    return r == true || r == 'true';
  }

  @override
  Future<void> goBack() async {
    _didGoBack = true;
    await _controller?.goBack();
  }

  @override
  Future<bool> canGoForward() async {
    // 简化处理：后退过后即可前进（与浏览器行为一致）。
    return _didGoBack;
  }

  @override
  Future<void> goForward() async {
    _didGoBack = false;
    await _controller?.goForward();
  }

  @override
  Future<void> reload() => _controller?.reload() ?? Future.value();

  @override
  Future<String?> currentUrl() async {
    final local = _url;
    if (local != null) return local;
    final r = await _controller?.evaluateJavascript('location.href');
    return r is String ? r : null;
  }

  @override
  Future<void> copyPageLink() async {
    final url = await currentUrl();
    if (url != null) {
      await Clipboard.setData(ClipboardData(text: url));
      _toast('已复制页面链接');
    }
  }

  @override
  Future<void> sharePage() async {
    final url = await currentUrl();
    if (url != null) await Share.share(url);
  }

  @override
  Future<void> copyAllText() async {
    final text = await _controller?.evaluateJavascript('''
(function() {
  var sel = window.getSelection ? window.getSelection().toString() : '';
  if (sel && sel.length > 0) return sel;
  return document.body ? (document.body.innerText || '') : '';
})();
''');
    if (text is String && text.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: text));
      _toast('已复制页面文本');
    } else {
      _toast('没有可复制的文本');
    }
  }

  @override
  Future<void> openExternal() async {
    final url = await currentUrl();
    if (url != null) {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 1),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final c = _controller;
    return Stack(
      children: [
        if (c != null)
          ValueListenableBuilder<bool>(
            valueListenable: c,
            builder: (context, ready, loading) =>
                ready ? c.webviewWidget : c.loadingWidget,
          )
        else
          const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        // CEF 无进度事件：加载期间顶部流动动画，结束即隐藏。
        if (_loading)
          const Align(
            alignment: Alignment.topCenter,
            child: LinearProgressIndicator(
              minHeight: 2.5,
              backgroundColor: Colors.transparent,
              valueColor: AlwaysStoppedAnimation(Color(0xFF5B5CE2)),
            ),
          ),
      ],
    );
  }
}
