library;

/// 注入页面的共享 JS 脚本（BrowserView 与 CefBrowserView 共用，避免两份实现漂移）。

/// 根节点 CSS 整页缩放。桌面 Chromium（WebView2 / CEF）下重排正确，
/// 与浏览器 Ctrl +/- 等效；z 为 1 时清除样式。
String kPageZoomScript(double z) => '''
(function() {
  try {
    document.documentElement.style.zoom = ($z === 1) ? '' : '$z';
    if (document.body) document.body.style.zoom = '';
  } catch (e) {}
})();
''';

/// 平移（抓手）模式：铺满可平移区域的拖拽层，拖动即滚动页面。
/// 覆盖层不能只有一屏大：原生缩放（Android 双指/按钮同一机制）放大
/// 后可平移区域远超一屏，固定层若只有 100vw/vh，屏外区域的
/// 触摸会漏给页面自身滚动，拖动就被 WebView 自己的滚动抢走。
/// touch-action:none + preventDefault 让拖拽层独占手势（代价是
/// 平移期间原生双指缩放也不可用，关掉平移即恢复）。
const String kPanLayerScript = '''
(function() {
  try {
    window.__zcodePanCleanup && window.__zcodePanCleanup();
    var el = document.createElement('div');
    el.id = '__zcode_pan_layer';
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
''';

/// 移除平移拖拽层。
const String kPanCleanupScript = 'window.__zcodePanCleanup && window.__zcodePanCleanup();';
