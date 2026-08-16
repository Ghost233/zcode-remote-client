import 'dart:collection' show UnmodifiableListView;
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/remote_device.dart';
import '../services/device_store.dart';
import 'browser_session.dart';
import 'glass.dart';
import 'web_scripts.dart';

/// 桌面模式使用的桌面版 Chrome UA（Windows）。
const kDesktopUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

/// 桌面模式视口脚本：把 viewport 钉在桌面宽度（1280），移动端响应式
/// 站点因此按桌面布局渲染——光换 UA 对按视口宽度适配的页面没有可见
/// 效果。SPA 若重建/改写 viewport 标签，会被 MutationObserver 再次覆盖。
/// 桌面端 WebView 本身忽略 viewport meta，注入后无副作用。
const String kDesktopViewportScript = '''
(function() {
  function apply() {
    try {
      var m = document.querySelector('meta[name="viewport"]');
      if (!m) {
        m = document.createElement('meta');
        m.setAttribute('name', 'viewport');
        (document.head || document.documentElement).appendChild(m);
      }
      if ((m.getAttribute('content') || '').indexOf('width=1280') < 0) {
        m.setAttribute('content', 'width=1280');
      }
    } catch (e) {}
  }
  var mo = new MutationObserver(function() {
    apply();
    hookMeta();
  });
  function hookMeta() {
    try {
      var m = document.head && document.head.querySelector('meta[name="viewport"]');
      if (m) mo.observe(m, { attributes: true, attributeFilter: ['content'] });
    } catch (e) {}
  }
  function hook() {
    if (!document.head) { setTimeout(hook, 20); return; }
    apply();
    try { mo.observe(document.head, { childList: true }); } catch (e) {}
    hookMeta();
  }
  hook();
})();
''';

/// 输入防护脚本已全部移除（v1.2.6）：自 v1.1.3 加入的 IME 组合态回车
/// 防护与后续所有发送后补救尝试都没能根治 macOS 中文输入问题，回到
/// v1.0.x 的裸 WebView 状态重新分析。已知副作用（回归预期内，遇到请
/// 记录反馈）：macOS 上组词途中按回车可能被页面误当成普通回车执行
/// 命令（WebKit Bug 165004）。

/// Android：把 WebView 原生（双指）缩放复位到 100%。
///
/// 双指缩放由 WebView 原生处理，不经应用内的缩放通知器（「页面缩放」
/// 在 Android 上是 textZoom 字体缩放，与双指缩放互相独立）。「回到
/// 100%」和切换会话的缩放重置都把双指缩放一并复位，避免双指放大后
/// 无法还原。zoomBy 是相对倍率：当前 scale 的倒数即复位。
/// 其他平台没有可编程复位的原生缩放，直接跳过。
Future<void> resetNativeZoom(InAppWebViewController? c) async {
  if (c == null || !Platform.isAndroid) return;
  final scale = await c.getZoomScale();
  if (scale == null || (scale - 1.0).abs() < 0.001) return;
  await c.zoomBy(zoomFactor: (1.0 / scale).clamp(0.02, 100.0));
}

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
    required this.onControllerReady,
    required this.onTitleChanged,
    required this.onReplaceAddress,
  });

  final RemoteDevice device;

  /// 页面缩放（1.0 = 100%）：浏览器 Ctrl +/- 式整页缩放，布局会重排。
  final ValueNotifier<double> pageZoom;

  final void Function(InAppWebViewController controller) onControllerReady;
  final void Function(String title) onTitleChanged;

  /// 加载失败时用户点了"替换地址"。
  final VoidCallback onReplaceAddress;

  @override
  State<BrowserView> createState() => BrowserViewState();
}

class BrowserViewState extends State<BrowserView>
    with AutomaticKeepAliveClientMixin
    implements BrowserSession {
  InAppWebViewController? _controller;
  PullToRefreshController? _pullToRefresh;
  InAppWebViewHitTestResult? _lastHitTest;
  double _progress = 0;
  WebResourceError? _mainFrameError;

  /// 平移（抓手）模式开关，工具栏读取/切换。
  @override
  final ValueNotifier<bool> panMode = ValueNotifier(false);

  /// 双指缩放开关（Android 触屏双指；macOS 触摸板捏合已否决——WKWebView
  /// 只有整页缩放，没有字体缩放，按钮置灰）。默认关，持久化。
  @override
  final ValueNotifier<bool> pinchZoom = ValueNotifier(false);

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    widget.pageZoom.addListener(_applyPageZoom);
    if (Platform.isAndroid) {
      pinchZoom.value = context.read<DeviceStore>().pinchZoomEnabled;
    }
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
    panMode.dispose();
    pinchZoom.dispose();
    super.dispose();
  }

  /// 开关平移模式：注入/移除页面内的拖拽层，拖动即滚动页面，
  /// 用于放大后把视野挪到关注的位置。桌面用鼠标拖，移动端用单指拖。
  /// 开启期间停用下拉刷新——它是 WebView 容器自己的滚动行为，
  /// 会和拖拽层抢手势（顶部下拉时触发刷新而不是平移）。
  @override
  Future<void> setPanMode(bool enabled) async {
    panMode.value = enabled;
    await _pullToRefresh?.setEnabled(!enabled);
    final c = _controller;
    if (c == null) return;
    if (enabled) {
      await _injectPanLayer(c);
    } else {
      await c.evaluateJavascript(source: kPanCleanupScript);
    }
  }

  /// 开关双指缩放（仅 Android：触屏双指），持久化选择。
  @override
  Future<void> setPinchZoom(bool enabled) async {
    pinchZoom.value = enabled;
    context.read<DeviceStore>().setPinchZoomEnabled(enabled);
    final c = _controller;
    if (c == null || !Platform.isAndroid) return;
    await _applyPinchSettings(c, enabled);
  }

  /// Android：双指缩放 = WebView 缩放设置（supportZoom + 内建缩放控件，
  /// 不显示系统缩放按钮）。运行时切换即时生效；插件默认是开，开关
  /// 默认关，所以 WebView 创建时也要按开关状态显式应用一次。
  Future<void> _applyPinchSettings(
    InAppWebViewController c,
    bool enabled,
  ) async {
    final settings = await c.getSettings();
    if (settings == null) return;
    settings.supportZoom = enabled;
    settings.builtInZoomControls = enabled;
    settings.displayZoomControls = false;
    await c.setSettings(settings: settings);
  }

  Future<void> _injectPanLayer(InAppWebViewController c) {
    return c.evaluateJavascript(source: kPanLayerScript);
  }

  /// 页面缩放（布局重排，等效浏览器 Ctrl +/-）。
  ///
  /// macOS/iOS：WKWebView 原生 pageZoom（实测 WebKit 下给根节点打 CSS
  /// zoom 不会重排 vw/vh 和 fixed 布局，页面会错乱；Apple 官方说明
  /// pageZoom 等价于浏览器整页缩放）。
  /// Android：系统级文字缩放 textZoom——只放大字体、按新字号重排布局，
  /// 不改布局视口，fixed 输入框不会被挤出屏幕（v1.1.10 的 body CSS
  /// zoom 会挤飞输入框；v1.2.3 用过的 zoomBy 原生缩放是「双指缩放那种」
  /// 整幅画面放大，用户要的是字体放大，故弃）。设置经 getSettings/
  /// setSettings 全量下发，textZoom 变化即时生效（插件 Android 实现
  /// 有专门分支）。
  /// Windows：插件未暴露 WebView2 的 ZoomFactor 设置口；桌面 Chromium
  /// 下 CSS zoom 根节点即可正确重排，保持 CSS 实现。
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
    } else if (Platform.isAndroid) {
      final settings = await c.getSettings();
      if (settings != null) {
        settings.textZoom = (z * 100).round();
        await c.setSettings(settings: settings);
      }
    } else {
      await c.evaluateJavascript(source: kPageZoomScript(z));
    }
  }

  // ---------- 会话接口：导航 ----------

  @override
  Future<bool> canGoBack() async =>
      await _controller?.canGoBack() ?? false;

  @override
  Future<void> goBack() => _controller?.goBack() ?? Future.value();

  @override
  Future<bool> canGoForward() async =>
      await _controller?.canGoForward() ?? false;

  @override
  Future<void> goForward() => _controller?.goForward() ?? Future.value();

  @override
  Future<void> reload() async {
    setState(() => _mainFrameError = null);
    await _controller?.loadUrl(
      urlRequest: URLRequest(url: WebUri(widget.device.url)),
    );
  }

  // ---------- 页面操作（供工具栏调用） ----------

  @override
  Future<String?> currentUrl() async =>
      (await _controller?.getUrl())?.toString();

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
    if (url != null) {
      await Share.share(url);
    }
  }

  @override
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
    // 桌面模式是"创建时"快照：UA / 原生 contentMode / 视口脚本都只能随
    // WebView 重建生效，切换开关时由外部重建当前会话。
    final desktopMode = context.watch<DeviceStore>().desktopMode;
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
            // 桌面模式三项配合，等效浏览器"桌面版网站"开关：
            // 1) 桌面 Chrome UA；2) iOS 原生 preferredContentMode（Safari
            //    "请求桌面网站"的实现）；3) 注入脚本把 viewport 钉在 1280
            //    宽（移动端按桌面宽度渲染，桌面端忽略 viewport 无副作用）。
            userAgent: desktopMode ? kDesktopUserAgent : null,
            preferredContentMode: desktopMode
                ? UserPreferredContentMode.DESKTOP
                : UserPreferredContentMode.RECOMMENDED,
          ),
          // 桌面模式注入视口脚本（把 viewport 钉在桌面宽度）。
          initialUserScripts: desktopMode
              ? UnmodifiableListView([
                  UserScript(
                    source: kDesktopViewportScript,
                    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                  ),
                ])
              : null,
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
            // 插件默认开双指缩放，开关默认关：创建时按开关状态显式应用。
            if (Platform.isAndroid) {
              _applyPinchSettings(controller, pinchZoom.value);
            }
          },
          onLoadStart: (controller, url) {
            setState(() => _mainFrameError = null);
          },
          onLoadStop: (controller, url) async {
            _pullToRefresh?.endRefreshing();
            setState(() => _progress = 1);
            // Windows 的 CSS 缩放打在文档上，新文档会丢，加载完重打。
            // 原生缩放（macOS pageZoom / Android textZoom）是 WebView
            // 自身属性，跨加载保留，不重放。
            if (Platform.isWindows) await _applyPageZoom();
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
          onDownloadStarting: (controller, request) async {
            // 下载交给系统浏览器/下载器处理。
            await launchUrl(request.url, mode: LaunchMode.externalApplication);
            _toast('已交给系统浏览器下载');
            // Windows 上取消 WebView2 自带的下载 UI（已外抛系统浏览器）。
            return DownloadStartResponse(
              handled: true,
              action: DownloadStartResponseAction.CANCEL,
            );
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
                        Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          alignment: WrapAlignment.center,
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
