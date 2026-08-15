import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/remote_device.dart';
import '../services/device_store.dart';
import 'glass.dart';

/// 桌面模式使用的桌面版 Chrome UA（Windows）。
const kDesktopUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

/// 单个设备对应的完整功能浏览器视图。
///
/// 覆盖能力：前进/后退/刷新、加载进度、JS 弹窗（alert/confirm/prompt）、
/// window.open 新窗口、自定义长按/右键菜单（复制/分享/外部打开）、
/// 下载、文件上传、权限请求、非 http 链接外抛、下拉刷新、错误重载页。
class BrowserView extends StatefulWidget {
  const BrowserView({
    super.key,
    required this.device,
    required this.pageZoom,
    required this.viewZoom,
    required this.onControllerReady,
    required this.onTitleChanged,
    required this.onReplaceAddress,
  });

  final RemoteDevice device;

  /// 页面缩放（1.0 = 100%）：CSS zoom，页面布局会重排，类似浏览器 Ctrl +/-。
  final ValueNotifier<double> pageZoom;

  /// 可视缩放（1.0 = 100%）：CSS transform scale，只放大可视范围，布局不重排。
  final ValueNotifier<double> viewZoom;

  final void Function(InAppWebViewController controller) onControllerReady;
  final void Function(String title) onTitleChanged;

  /// 加载失败时用户点了"替换地址"。
  final VoidCallback onReplaceAddress;

  @override
  State<BrowserView> createState() => BrowserViewState();
}

class BrowserViewState extends State<BrowserView>
    with AutomaticKeepAliveClientMixin {
  InAppWebViewController? _controller;
  PullToRefreshController? _pullToRefresh;
  InAppWebViewHitTestResult? _lastHitTest;
  double _progress = 0;
  WebResourceError? _mainFrameError;

  /// 平移（抓手）模式开关，工具栏读取/切换。
  final ValueNotifier<bool> panMode = ValueNotifier(false);

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    widget.pageZoom.addListener(_applyPageZoom);
    widget.viewZoom.addListener(_applyViewZoom);
    // 下拉刷新控制器只有移动端有实现，桌面端构造会抛 UnimplementedError。
    if (Platform.isIOS || Platform.isAndroid) {
      _pullToRefresh = PullToRefreshController(
        settings: PullToRefreshSettings(
          color: const Color(0xFF5B5CE2),
          backgroundColor: Colors.transparent,
        ),
        onRefresh: () async {
          final c = _controller;
          if (c != null) await c.reload();
        },
      );
    }
  }

  @override
  void dispose() {
    widget.pageZoom.removeListener(_applyPageZoom);
    widget.viewZoom.removeListener(_applyViewZoom);
    panMode.dispose();
    super.dispose();
  }

  /// 开关平移模式：注入/移除页面内的拖拽层，拖动即滚动页面，
  /// 用于放大后把视野挪到关注的位置。桌面用鼠标拖，移动端用单指拖。
  Future<void> setPanMode(bool enabled) async {
    panMode.value = enabled;
    final c = _controller;
    if (c == null) return;
    if (enabled) {
      await _injectPanLayer(c);
    } else {
      await c.evaluateJavascript(
        source: 'window.__zcodePanCleanup && window.__zcodePanCleanup();',
      );
    }
  }

  Future<void> _injectPanLayer(InAppWebViewController c) {
    return c.evaluateJavascript(
      source: '''
(function() {
  try {
    window.__zcodePanCleanup && window.__zcodePanCleanup();
    var el = document.createElement('div');
    el.id = '__zcode_pan_layer';
    el.style.cssText = 'position:fixed;left:0;top:0;width:100vw;height:100vh;'
      + 'z-index:2147483647;cursor:grab;touch-action:none;';
    var dragging = false, sx = 0, sy = 0;
    function down(x, y) { dragging = true; sx = x; sy = y; el.style.cursor = 'grabbing'; }
    function move(x, y) {
      if (!dragging) return;
      window.scrollBy(sx - x, sy - y);
      sx = x; sy = y;
    }
    function up() { dragging = false; el.style.cursor = 'grab'; }
    el.addEventListener('mousedown', function(e) { down(e.clientX, e.clientY); e.preventDefault(); });
    window.addEventListener('mousemove', function(e) { move(e.clientX, e.clientY); });
    window.addEventListener('mouseup', up);
    el.addEventListener('touchstart', function(e) {
      var t = e.touches[0]; down(t.clientX, t.clientY); e.preventDefault();
    }, { passive: false });
    el.addEventListener('touchmove', function(e) {
      var t = e.touches[0]; move(t.clientX, t.clientY); e.preventDefault();
    }, { passive: false });
    el.addEventListener('touchend', up);
    document.documentElement.appendChild(el);
    window.__zcodePanCleanup = function() { el.remove(); window.__zcodePanCleanup = null; };
  } catch (e) {}
})();
''',
    );
  }

  /// 页面缩放（布局重排，等效浏览器整页缩放）。
  ///
  /// 实测（用 WKWebView 测试程序验证）：WebKit 下给根节点打 CSS zoom
  /// 不会重排 vw/vh 和 fixed 布局，页面会错乱；必须用 WKWebView 原生
  /// pageZoom（Apple 官方说明其等价于浏览器整页缩放）。
  /// Chromium 系（Android / Windows WebView2）用 CSS zoom 根节点即可正确重排。
  Future<void> _applyPageZoom() async {
    final c = _controller;
    if (c == null) return;
    final z = widget.pageZoom.value;
    if (Platform.isIOS || Platform.isMacOS) {
      final settings = await c.getSettings();
      if (settings != null) {
        settings.pageZoom = z;
        await c.setSettings(settings: settings);
      }
    } else {
      await c.evaluateJavascript(
        source:
            '''
(function() {
  try {
    document.documentElement.style.zoom = '$z';
    if (document.body) document.body.style.zoom = '';
  } catch (e) {}
})();
''',
      );
    }
  }

  /// 可视缩放：CSS transform scale，只放大可视范围，不改变页面布局。
  /// 同时把 html 的最小可视区域按倍率放大，保证缩放后的内容可以滚动到。
  Future<void> _applyViewZoom() async {
    final c = _controller;
    if (c == null) return;
    final z = widget.viewZoom.value;
    await c.evaluateJavascript(
      source:
          '''
(function() {
  try {
    var b = document.body, d = document.documentElement;
    if (!b) return;
    b.style.transformOrigin = '0 0';
    b.style.transform = ($z === 1) ? '' : 'scale($z)';
    d.style.minHeight = ($z * 100) + 'vh';
    d.style.minWidth = ($z * 100) + 'vw';
  } catch (e) {}
})();
''',
    );
  }

  Future<void> reload() async {
    setState(() => _mainFrameError = null);
    await _controller?.loadUrl(
      urlRequest: URLRequest(url: WebUri(widget.device.url)),
    );
  }

  // ---------- 页面操作（供工具栏调用） ----------

  Future<String?> currentUrl() async =>
      (await _controller?.getUrl())?.toString();

  Future<void> copyPageLink() async {
    final url = await currentUrl();
    if (url != null) {
      await Clipboard.setData(ClipboardData(text: url));
      _toast('已复制页面链接');
    }
  }

  Future<void> sharePage() async {
    final url = await currentUrl();
    if (url != null) {
      await Share.share(url);
    }
  }

  Future<void> copyAllText() async {
    final text = await _controller?.evaluateJavascript(
      source: '''
(function() {
  var sel = window.getSelection ? window.getSelection().toString() : '';
  if (sel && sel.length > 0) return sel;
  return document.body ? (document.body.innerText || '') : '';
})();
''',
    );
    if (text is String && text.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: text));
      _toast('已复制页面文本');
    } else {
      _toast('没有可复制的文本');
    }
  }

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

  // ---------- 长按/右键菜单 ----------

  /// 命中结果里的链接地址：锚点/图片类命中时 extra 存的是 URL。
  String? get _hitLink {
    final extra = _lastHitTest?.extra;
    if (extra != null && extra.startsWith('http')) return extra;
    return null;
  }

  Future<void> _copySelectionOrText() async {
    final selected = await _controller?.evaluateJavascript(
      source: 'window.getSelection ? window.getSelection().toString() : ""',
    );
    final text = (selected is String && selected.isNotEmpty)
        ? selected
        : _lastHitTest?.extra;
    if (text != null && text.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: text));
      _toast('已复制');
    } else {
      _toast('没有可复制的文本');
    }
  }

  Future<void> _copyHitLink() async {
    final link = _hitLink ?? await currentUrl();
    if (link != null) {
      await Clipboard.setData(ClipboardData(text: link));
      _toast('已复制链接');
    }
  }

  Future<void> _shareHitLink() async {
    final link = _hitLink ?? await currentUrl();
    if (link != null) await Share.share(link);
  }

  Future<void> _openHitLinkExternal() async {
    final link = _hitLink ?? await currentUrl();
    if (link != null) {
      await launchUrl(Uri.parse(link), mode: LaunchMode.externalApplication);
    }
  }

  // ---------- JS 弹窗 ----------

  Future<JsAlertResponse?> _onJsAlert(
    InAppWebViewController c,
    JsAlertRequest req,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(req.message ?? ''),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('好'),
          ),
        ],
      ),
    );
    return JsAlertResponse(
      handledByClient: true,
      action: JsAlertResponseAction.CONFIRM,
    );
  }

  Future<JsConfirmResponse?> _onJsConfirm(
    InAppWebViewController c,
    JsConfirmRequest req,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(req.message ?? ''),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    return JsConfirmResponse(
      handledByClient: true,
      action: (ok ?? false)
          ? JsConfirmResponseAction.CONFIRM
          : JsConfirmResponseAction.CANCEL,
    );
  }

  Future<JsPromptResponse?> _onJsPrompt(
    InAppWebViewController c,
    JsPromptRequest req,
  ) async {
    final controller = TextEditingController(text: req.defaultValue ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(req.message ?? ''),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    return JsPromptResponse(
      handledByClient: true,
      action: (ok ?? false)
          ? JsPromptResponseAction.CONFIRM
          : JsPromptResponseAction.CANCEL,
      value: controller.text,
    );
  }

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Stack(
      children: [
        InAppWebView(
          initialUrlRequest: URLRequest(url: WebUri(widget.device.url)),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            useShouldOverrideUrlLoading: true,
            useOnDownloadStart: true,
            supportMultipleWindows: true,
            javaScriptCanOpenWindowsAutomatically: true,
            mediaPlaybackRequiresUserGesture: false,
            allowsInlineMediaPlayback: true,
            // iOS 侧滑前进/后退
            allowsBackForwardNavigationGestures: true,
            isFraudulentWebsiteWarningEnabled: false,
            disableContextMenu: false,
            // 桌面模式：用桌面 Chrome UA 请求站点（UA 只能在创建时设置，
            // 切换时由外部重建会话生效）。
            userAgent: context.watch<DeviceStore>().desktopMode
                ? kDesktopUserAgent
                : null,
          ),
          pullToRefreshController: _pullToRefresh,
          contextMenu: ContextMenu(
            settings: ContextMenuSettings(
              hideDefaultSystemContextMenuItems: false,
            ),
            onCreateContextMenu: (hitTestResult) {
              _lastHitTest = hitTestResult;
            },
            menuItems: [
              ContextMenuItem(id: 1, title: '复制', action: _copySelectionOrText),
              ContextMenuItem(id: 2, title: '复制链接', action: _copyHitLink),
              ContextMenuItem(id: 3, title: '分享', action: _shareHitLink),
              ContextMenuItem(
                id: 4,
                title: '在浏览器打开',
                action: _openHitLinkExternal,
              ),
            ],
          ),
          onWebViewCreated: (controller) {
            _controller = controller;
            widget.onControllerReady(controller);
          },
          onLoadStart: (controller, url) {
            setState(() => _mainFrameError = null);
          },
          onLoadStop: (controller, url) async {
            _pullToRefresh?.endRefreshing();
            setState(() => _progress = 1);
            await _applyPageZoom();
            await _applyViewZoom();
            // 新文档会清掉注入的拖拽层，平移模式开着的话重新注入。
            if (panMode.value) await _injectPanLayer(controller);
          },
          onProgressChanged: (controller, progress) {
            setState(() => _progress = progress / 100);
            if (progress >= 100) _pullToRefresh?.endRefreshing();
          },
          onReceivedError: (controller, request, error) {
            _pullToRefresh?.endRefreshing();
            if (request.isForMainFrame ?? false) {
              setState(() => _mainFrameError = error);
            }
          },
          onTitleChanged: (controller, title) {
            if (title != null) widget.onTitleChanged(title);
          },
          onJsAlert: _onJsAlert,
          onJsConfirm: _onJsConfirm,
          onJsPrompt: _onJsPrompt,
          onCreateWindow: (controller, action) async {
            // window.open / target=_blank：在当前视图加载，保持单页体验。
            final url = action.request.url;
            if (url != null) {
              await controller.loadUrl(urlRequest: URLRequest(url: url));
            }
            return true;
          },
          onDownloadStartRequest: (controller, request) async {
            // 下载交给系统浏览器/下载器处理。
            await launchUrl(request.url, mode: LaunchMode.externalApplication);
            _toast('已交给系统浏览器下载');
          },
          shouldOverrideUrlLoading: (controller, action) async {
            final uri = action.request.url;
            if (uri == null) return NavigationActionPolicy.ALLOW;
            const allowed = {
              'http',
              'https',
              'about',
              'data',
              'blob',
              'file',
              'javascript',
            };
            if (!allowed.contains(uri.scheme.toLowerCase())) {
              // mailto/tel/intent/自定义协议 → 系统处理。
              await launchUrl(uri, mode: LaunchMode.externalApplication);
              return NavigationActionPolicy.CANCEL;
            }
            return NavigationActionPolicy.ALLOW;
          },
          onPermissionRequest: (controller, request) async {
            // 专用客户端：页面请求相机/麦克风/剪贴板等权限直接授予。
            return PermissionResponse(
              resources: request.resources,
              action: PermissionResponseAction.GRANT,
            );
          },
          // 文件上传（<input type=file>）由插件在各平台原生处理。
        ),

        // 顶部细进度条
        if (_progress < 1)
          Align(
            alignment: Alignment.topCenter,
            child: LinearProgressIndicator(
              value: _progress,
              minHeight: 2.5,
              backgroundColor: Colors.transparent,
              valueColor: const AlwaysStoppedAnimation(Color(0xFF5B5CE2)),
            ),
          ),

        // 主框架加载失败的玻璃错误页
        if (_mainFrameError != null)
          Positioned.fill(
            child: Container(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: GlassContainer(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 28,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.cloud_off_rounded,
                          size: 48,
                          color: Colors.grey,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          '页面加载失败',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _mainFrameError!.description,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '连接地址可能已失效，可以重试或替换为新地址',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 20),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            OutlinedButton.icon(
                              onPressed: reload,
                              icon: const Icon(Icons.refresh, size: 18),
                              label: const Text('重新加载'),
                            ),
                            const SizedBox(width: 12),
                            FilledButton.icon(
                              onPressed: widget.onReplaceAddress,
                              icon: const Icon(Icons.edit_note, size: 18),
                              label: const Text('替换地址'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
