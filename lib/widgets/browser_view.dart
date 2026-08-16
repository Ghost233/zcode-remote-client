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
import 'glass.dart';

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

/// 输入法组合态回车保护 v2。
///
/// 要同时扛住两类引擎行为：
/// 1) Chromium（Android/Windows）：组合中的按键 keydown 恒为 keyCode=229，
///    提交组合的那次回车要么被内核消费、要么以 229 形态到达（符合规范）。
/// 2) WebKit（macOS/iOS 内核，Bug 165004，2026-04 才修，存量系统带病）：
///    先派发 compositionend（组合文本上屏），之后才派发"提交组合的那次
///    回车"，且 isComposing=false——对页面完全伪装成普通回车。网页自身
///    的 isComposing 防御（如 ZCode 的 Lexical 输入框）因此全部失效，
///    表现为：/com 组合中按回车 → 直接执行了高亮建议 /compact。
///
/// 防线（业界同款：ProseMirror/CodeMirror 6 的 Safari 一次性吞键窗口、
/// stum.de 的非回车键复位、MDN 的 isComposing||229 双查）：
/// - window 捕获阶段拦截 Enter 形状的 keydown/keypress/keyup，判定命中
///   组合态时 stopImmediatePropagation；只 stop、绝不 preventDefault——
///   组合期取消 keydown 会杀掉输入法上屏（W3C UI Events）。
/// - 判定：e.isComposing || 自维护组合标志（compositionend 后延迟清零）
///   || keyCode/which=229 || key='Process'。
/// - WebKit 专属兜底（仅 macOS 启用）：compositionend 后 300ms 内的第一记
///   回车视为"提交组合的那次按键"，一次性吞掉；期间若先来了任何非回车
///   keydown（空格/数字选词的尾随按键），说明组合不是回车确认的，撤销
///   窗口，避免误吞用户随后的真实回车。iOS 不启用（可能根本不派发尾随
///   回车，盲开会吞掉用户选词后的真实回车）；Chromium 不需要（尾随回车
///   在 compositionend 之前已到达）。
/// - 事件环形日志 window.__zcodeImeLog（60 条），排查输入法问题时可从
///   控制台或 evaluateJavascript 读取。
/// - WebKit 专属自愈：发送一条消息后打不进字（打一个字像被删一个字）。
///   根因是页面发送后程序化清空仍持有焦点的编辑框，WKWebView 的文本
///   输入会话（含上次组合输入的标记文本状态）残留失效；检测到"真实
///   回车放行后编辑框被清空"即 blur+focus 强制重建输入会话。
String imeEnterGuardScript({required bool webkit}) => '''
(function() {
  if (window.__zcodeImeGuard) return;
  window.__zcodeImeGuard = true;
  var IS_WEBKIT = ${webkit ? 'true' : 'false'};
  var GRACE_MS = 300;
  var composing = false;
  var endedAt = 0;
  var swallowOnce = false;
  var swallowKeyup = false;
  var log = [];
  window.__zcodeImeLog = log;
  function rec(o) {
    o.t = Date.now();
    log.push(o);
    if (log.length > 60) log.shift();
  }
  window.addEventListener('compositionstart', function() {
    composing = true;
    rec({type: 'compositionstart'});
  }, true);
  window.addEventListener('compositionend', function() {
    endedAt = Date.now();
    if (IS_WEBKIT) swallowOnce = true;
    // 延迟清零扛"end 与回车同批派发"，但独立的回车任务到来前定时器可能
    // 已执行——WebKit 的主要防线是上面的一次性窗口。
    setTimeout(function() { composing = false; }, 0);
    rec({type: 'compositionend'});
  }, true);
  function guard(e) {
    var enter = e.key === 'Enter' || e.keyCode === 13;
    if (!enter) {
      // 非回车 keydown 先到：组合是用空格/数字等别的键确认的（其尾随
      // keydown 现在才到），撤销吞键窗口，防误吞用户随后的真实回车。
      if (e.type === 'keydown' && swallowOnce) swallowOnce = false;
      return;
    }
    var owned = e.isComposing || composing ||
        e.keyCode === 229 || e.which === 229 || e.key === 'Process';
    if (!owned && swallowOnce) {
      if (Date.now() - endedAt < GRACE_MS) owned = true;
      else swallowOnce = false;
    }
    rec({type: e.type, key: e.key, keyCode: e.keyCode,
         isComposing: !!e.isComposing, owned: owned});
    if (!owned) {
      swallowKeyup = false;
      return;
    }
    if (e.type === 'keydown') {
      swallowOnce = false;
      swallowKeyup = true;
    } else if (e.type === 'keyup' && swallowKeyup) {
      swallowKeyup = false;
    }
    e.stopImmediatePropagation();
    e.stopPropagation();
  }
  window.addEventListener('keydown', guard, true);
  window.addEventListener('keypress', guard, true);
  window.addEventListener('keyup', guard, true);
  if (IS_WEBKIT) {
    // 发送后输入会话自愈（仅 macOS）。注册在 guard 之后：guard 吞掉的
    // 幽灵回车（stopImmediatePropagation）不会到达这里，这里看到的
    // 只会是用户真实的回车。真实回车后若编辑框随后被页面清空（= 一条
    // 消息发送成功），blur+focus 强制 WebKit 丢弃失效的输入会话重建，
    // 否则下一条消息会"打一个字被删一个字"或完全打不进。
    window.addEventListener('keydown', function(e) {
      if (e.key !== 'Enter' && e.keyCode !== 13) return;
      var el = document.activeElement;
      if (!el) return;
      var editable = el.isContentEditable ||
          /^(INPUT|TEXTAREA)$/.test(el.tagName || '');
      if (!editable) return;
      var checks = 0;
      var timer = setInterval(function() {
        checks++;
        var stillFocused = document.activeElement === el;
        var empty = stillFocused && (el.isContentEditable
            ? (el.textContent || '').trim() === ''
            : !el.value);
        if (empty) {
          clearInterval(timer);
          el.blur();
          el.focus();
          rec({type: 'postSendRefocus'});
        } else if (checks >= 6 || !stillFocused) {
          clearInterval(timer);
        }
      }, 100);
    }, true);
  }
})();
''';

/// Android：把 WebView 原生（双指）缩放复位到 100%。
///
/// Android 的双指缩放/平移由 WebView 原生处理（已取代被移除的「页面
/// 缩放」），工具栏「回到 100%」和切换会话的缩放重置都要把它一并
/// 复位，否则双指放大后点 100% 只复位可视缩放、画面不动。
/// zoomBy 是相对倍率：当前 scale 的倒数即复位。其他平台没有可编程
/// 复位的原生缩放，直接跳过。
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
    required this.viewZoom,
    required this.onControllerReady,
    required this.onTitleChanged,
    required this.onReplaceAddress,
  });

  final RemoteDevice device;

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
    widget.viewZoom.removeListener(_applyViewZoom);
    panMode.dispose();
    super.dispose();
  }

  /// 开关平移模式：注入/移除页面内的拖拽层，拖动即滚动页面，
  /// 用于放大后把视野挪到关注的位置。桌面用鼠标拖，移动端用单指拖。
  /// 开启期间停用下拉刷新——它是 WebView 容器自己的滚动行为，
  /// 会和拖拽层抢手势（顶部下拉时触发刷新而不是平移）。
  Future<void> setPanMode(bool enabled) async {
    panMode.value = enabled;
    await _pullToRefresh?.setEnabled(!enabled);
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
    // 覆盖层不能只有一屏大：可视缩放（min 尺寸撑大文档）和原生双指
    // 缩放后，可平移区域远超一屏，固定层若只有 100vw/vh，屏外区域的
    // 触摸会漏给页面自身滚动，拖动就被 WebView 自己的滚动抢走。
    // touch-action:none + preventDefault 让拖拽层独占手势（代价是
    // 平移期间原生双指缩放也不可用，关掉平移即恢复）。
    el.style.cssText = 'position:fixed;left:0;top:0;z-index:2147483647;'
      + 'cursor:grab;touch-action:none;overscroll-behavior:contain;';
    var dragging = false, sx = 0, sy = 0;
    function cover() {
      var d = document.documentElement;
      el.style.width = Math.max(window.innerWidth, d.scrollWidth) + 'px';
      el.style.height = Math.max(window.innerHeight, d.scrollHeight) + 'px';
    }
    function down(x, y) { dragging = true; sx = x; sy = y; el.style.cursor = 'grabbing'; cover(); }
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
    cover();
    document.documentElement.appendChild(el);
    window.__zcodePanCleanup = function() { el.remove(); window.__zcodePanCleanup = null; };
  } catch (e) {}
})();
''',
    );
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
          // 常驻：输入法组合态回车保护（修中文输入法组词途中回车误发送/
          // 误执行命令）；forMainFrameOnly: false 让脚本进所有 frame。
          // 桌面模式追加视口脚本。
          initialUserScripts: UnmodifiableListView([
            UserScript(
              source: imeEnterGuardScript(webkit: Platform.isMacOS),
              injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
              forMainFrameOnly: false,
            ),
            if (desktopMode)
              UserScript(
                source: kDesktopViewportScript,
                injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
              ),
          ]),
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
