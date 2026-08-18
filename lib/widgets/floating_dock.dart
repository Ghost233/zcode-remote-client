import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';

import '../services/device_store.dart';
import 'browser_session.dart';
import 'browser_view.dart';
import 'glass.dart';
import 'update_dialog.dart';

/// 悬浮控制栏（悬浮球 + 工具栏二合一）。
///
/// 收起态：圆形玻璃悬浮球（终端图标），点击展开；可整球拖拽、吸附左右
/// 边缘；闲置 3 秒自动吸附到最右侧，累计 5 秒透明度降得更低。
/// 展开态：竖排玻璃工具栏——设备切换、前进/后退/刷新、macOS 系统浏览
/// 器入口、平移模式、页面缩放（浏览器 Ctrl +/- 式）、页面操作菜单
/// （含桌面版网站开关）；
/// 按住顶部把手拖动，位置持久化，展开期间不收起、不淡化。
/// 从设置/面板隐藏后变成贴边细把手，点击恢复。
///
/// [compact]：分屏窗格用的小号版（球/栏/图标都小一号），每窗格一个、
/// 只控制本窗格的会话。此时必须 [persistPosition] = false——位置只活在
/// 实例内存里，不写全局偏好（否则几个小球互相抢单屏悬浮球的位置），
/// 闲置自动吸附到 [initialDx] 指定的边缘（0=左，1=右）。
class FloatingDock extends StatefulWidget {
  const FloatingDock({
    super.key,
    required this.controller,
    required this.viewKey,
    required this.pageZoom,
    required this.onReplaceAddress,
    required this.onOpenSwitcher,
    required this.onDesktopModeChanged,
    required this.onOpenSettings,
    this.compact = false,
    this.persistPosition = true,
    this.initialDx = 1.0,
  });

  /// 当前页的 WebView 控制器（无打开会话时为 null）。
  final InAppWebViewController? controller;

  /// 当前浏览器会话视图的 key，currentState 实现 BrowserSession 接口，
  /// 供导航/页面操作调用。
  final GlobalKey? viewKey;

  /// 页面缩放（浏览器 Ctrl +/- 式整页缩放，布局重排）。
  final ValueNotifier<double> pageZoom;

  final VoidCallback onReplaceAddress;

  /// 打开设备切换面板。
  final VoidCallback onOpenSwitcher;

  /// 桌面模式切换后的回调（外部用它重建当前会话使 UA 生效）。
  final VoidCallback onDesktopModeChanged;

  /// 打开设置页。
  final VoidCallback onOpenSettings;

  /// 紧凑模式：分屏窗格内的小号悬浮球。
  final bool compact;

  /// 位置是否持久化到全局偏好。分屏窗格的小球必须为 false。
  final bool persistPosition;

  /// 不持久化时的初始/闲置吸附边缘（0=左边缘，1=右边缘）。
  final double initialDx;

  @override
  State<FloatingDock> createState() => _FloatingDockState();
}

class _FloatingDockState extends State<FloatingDock> {
  static const double _minZoom = 0.5;
  static const double _maxZoom = 3.0;

  double get _bubbleSize => widget.compact ? 40 : 52;
  double get _barWidth => widget.compact ? 46 : 56;
  double get _iconSize => widget.compact ? 18 : 22;

  bool _expanded = false;
  bool _dimmed = false;
  Timer? _snapTimer;
  Timer? _dimTimer;

  // 位置（0..1 比例），dx 吸附后只会是 0 或 1；默认右边缘中部。
  double? _dx;
  double _dy = 0.5;
  bool _initialized = false;

  /// 控制栏自身的 key，拖拽时用它量真实尺寸。
  final GlobalKey _dockKey = GlobalKey();
  double _containerW = 0;
  double _containerH = 0;

  @override
  void dispose() {
    _snapTimer?.cancel();
    _dimTimer?.cancel();
    super.dispose();
  }

  /// 闲置自动行为（仅收起态的悬浮球；展开的工具栏不受影响）：
  /// 3 秒不动 → 自动吸附到边缘（单屏球固定最右侧，窗格小球回到
  /// 自己的外侧边缘）；累计 5 秒不动 → 透明度降得更低。
  void _armIdleTimers() {
    _snapTimer?.cancel();
    _dimTimer?.cancel();
    if (_expanded) return;
    final target = widget.persistPosition ? 1.0 : widget.initialDx;
    _snapTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted || _expanded) return;
      setState(() => _dx = target);
      if (widget.persistPosition) {
        context.read<DeviceStore>().setToolbarPosition(target, _dy);
      }
    });
    _dimTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted || _expanded) return;
      setState(() => _dimmed = true);
    });
  }

  void _wake() {
    if (_dimmed) setState(() => _dimmed = false);
    _armIdleTimers();
  }

  void _setZoom(ValueNotifier<double> notifier, double v, double step) {
    final snapped = (v / step).round() * step;
    notifier.value = double.parse(
      snapped.toStringAsFixed(2),
    ).clamp(_minZoom, _maxZoom);
  }

  /// 「更多」面板：网页操作 + 偏好开关 + 应用入口（设置/检查更新）
  /// 集中在一个地方，和专职的「切换设备」按钮不再混淆。
  void _showActions() {
    final BrowserSession? view = sessionOf(widget.viewKey);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: kGlassBarrierColor,
      builder: (ctx) {
        Widget item(
          IconData icon,
          String label,
          VoidCallback? action, {
          Color? color,
        }) {
          return ListTile(
            leading: Icon(icon, color: color),
            title: Text(label, style: TextStyle(color: color)),
            dense: true,
            onTap: action == null
                ? null
                : () {
                    Navigator.of(ctx).pop();
                    action();
                  },
          );
        }

        Widget sectionLabel(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
          child: Text(
            text,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Theme.of(ctx).colorScheme.primary,
            ),
          ),
        );

        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: GlassContainer(
            padding: const EdgeInsets.symmetric(vertical: 6),
            // 内容较多（三分区），小屏下超出弹窗高度时必须可滚动。
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  sectionLabel('网页'),
                  item(
                    Icons.link,
                    '复制页面链接',
                    view == null ? null : () => view.copyPageLink(),
                  ),
                  item(
                    Icons.ios_share,
                    '分享当前页面',
                    view == null ? null : () => view.sharePage(),
                  ),
                  item(
                    Icons.copy_all,
                    '复制页面全部文本',
                    view == null ? null : () => view.copyAllText(),
                  ),
                  item(
                    Icons.open_in_new,
                    '在系统浏览器中打开',
                    view == null ? null : () => view.openExternal(),
                  ),
                  item(
                    Icons.refresh,
                    '重新加载',
                    view == null ? null : () => view.reload(),
                  ),
                  item(Icons.edit_note, '替换此设备地址', widget.onReplaceAddress),
                  const Divider(height: 6, indent: 16, endIndent: 16),
                  sectionLabel('偏好'),
                  // 桌面版网站：切换 UA，重建当前会话生效。
                  Consumer<DeviceStore>(
                    builder: (ctx, store, _) => SwitchListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                      ),
                      secondary: const Icon(Icons.desktop_windows_outlined),
                      title: const Text('桌面版网站'),
                      dense: true,
                      value: store.desktopMode,
                      onChanged: (v) {
                        Navigator.of(ctx).pop();
                        store.setDesktopMode(v).then((_) {
                          widget.onDesktopModeChanged();
                        });
                      },
                    ),
                  ),
                  // 后台保活：退后台挂前台服务保持 ZCode 会话连接不刷新。
                  // 仅 Android——iOS 系统不允许第三方后台保活。
                  if (Platform.isAndroid)
                    Consumer<DeviceStore>(
                      builder: (ctx, store, _) => SwitchListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                        ),
                        secondary: const Icon(Icons.all_inclusive_outlined),
                        title: const Text('后台保活'),
                        subtitle: const Text('退后台保持会话连接，回来不刷新'),
                        dense: true,
                        value: store.keepAliveEnabled,
                        onChanged: store.setKeepAliveEnabled,
                      ),
                    ),
                  const Divider(height: 6, indent: 16, endIndent: 16),
                  sectionLabel('应用'),
                  item(Icons.settings_outlined, '设置', widget.onOpenSettings),
                  item(
                    Icons.system_update,
                    '检查更新',
                    () => checkForUpdates(ctx, manual: true),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final box = _dockKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final maxX = _containerW - box.size.width;
    final maxY = _containerH - box.size.height;
    if (maxX <= 0 || maxY <= 0) return;
    setState(() {
      _dx = ((_dx! * maxX) + details.delta.dx) / maxX;
      _dy = ((_dy * maxY) + details.delta.dy) / maxY;
      _dx = _dx!.clamp(0.0, 1.0);
      _dy = _dy.clamp(0.0, 1.0);
    });
  }

  void _onDragEnd(DragEndDetails _) {
    final snapped = _dx! < 0.5 ? 0.0 : 1.0;
    setState(() => _dx = snapped);
    if (widget.persistPosition) {
      context.read<DeviceStore>().setToolbarPosition(snapped, _dy);
    }
    _armIdleTimers();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<DeviceStore>();
    if (!_initialized) {
      if (widget.persistPosition) {
        _dx = store.toolbarDx ?? 1.0; // 默认右边缘
        _dy = store.toolbarDy ?? 0.5;
      } else {
        _dx = widget.initialDx;
        _dy = 0.5;
      }
      _initialized = true;
      _armIdleTimers();
    }

    if (!store.bubbleEnabled) {
      return _buildHiddenHandle(store);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        _containerW = constraints.maxWidth;
        _containerH = constraints.maxHeight;
        final width = _expanded ? _barWidth : _bubbleSize;
        // macOS 多「系统浏览器打开」+「双指缩放」，Android 多「双指缩放
        // 复位」+「双指缩放」，展开态估高多一些（仅用于拖动范围钳制，
        // 超高由 SingleChildScrollView 兜底）。
        final estimatedHeight = _expanded
            ? (Platform.isMacOS
                  ? 610.0
                  : Platform.isAndroid
                  ? 620.0
                  : 530.0)
            : _bubbleSize;
        final maxX = (constraints.maxWidth - width).clamp(0.0, double.infinity);
        final maxY = (constraints.maxHeight - estimatedHeight).clamp(
          0.0,
          double.infinity,
        );
        final x = (_dx! * maxX).clamp(0.0, maxX);
        final y = (_dy * maxY).clamp(0.0, maxY);

        return Stack(
          children: [
            Positioned(
              left: x,
              top: y,
              child: AnimatedOpacity(
                opacity: _dimmed ? 0.2 : 1.0,
                duration: const Duration(milliseconds: 400),
                child: GlassContainer(
                  key: _dockKey,
                  borderRadius: _expanded
                      ? (widget.compact ? 22.0 : 28.0)
                      : _bubbleSize / 2,
                  padding: _expanded
                      ? const EdgeInsets.symmetric(horizontal: 4, vertical: 6)
                      : EdgeInsets.zero,
                  child: _expanded ? _buildExpanded() : _buildCollapsed(),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 隐藏模式：贴边细把手，点击恢复悬浮球。
  Widget _buildHiddenHandle(DeviceStore store) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const pillHeight = 72.0;
        final pillY = (_dy * (constraints.maxHeight - pillHeight)).clamp(
          0.0,
          constraints.maxHeight - pillHeight,
        );
        return Stack(
          children: [
            Positioned(
              left: _dx == 0 ? 0 : null,
              right: _dx == 0 ? null : 0,
              top: pillY,
              child: GestureDetector(
                onTap: () {
                  store.setBubbleEnabled(true);
                  _armIdleTimers();
                },
                child: Container(
                  width: 8,
                  height: pillHeight,
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.horizontal(
                      left: _dx == 0 ? Radius.zero : const Radius.circular(6),
                      right: _dx == 0 ? const Radius.circular(6) : Radius.zero,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 收起态：圆形悬浮球，点击展开工具栏；整球可拖拽。
  Widget _buildCollapsed() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        _wake();
        setState(() => _expanded = true);
      },
      onPanStart: (_) => _wake(),
      onPanUpdate: _onDragUpdate,
      onPanEnd: _onDragEnd,
      child: SizedBox(
        width: _bubbleSize,
        height: _bubbleSize,
        child: Icon(
          Icons.terminal_rounded,
          size: widget.compact ? 20 : 26,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }

  /// 工具栏图标按钮：紧凑模式下图标小一号。
  Widget _btn(IconData icon, String tooltip, VoidCallback? onPressed) {
    return GlassIconButton(
      icon: icon,
      tooltip: tooltip,
      onPressed: onPressed,
      size: _iconSize,
    );
  }

  /// 展开态：顶部拖拽把手 + 完整工具栏。
  /// 限高 + 滚动：矮屏（横屏手机）下按钮再多也不能溢出。
  Widget _buildExpanded() {
    final session = sessionOf(widget.viewKey);
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: _containerH > 0 ? _containerH : double.infinity,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildGrip(),
            _btn(Icons.devices_rounded, '切换设备', widget.onOpenSwitcher),
            const _Divider(),
            _btn(
              Icons.arrow_back_ios_new,
              '后退',
              session == null
                  ? null
                  : () async {
                      if (await session.canGoBack()) session.goBack();
                    },
            ),
            _btn(
              Icons.arrow_forward_ios,
              '前进',
              session == null
                  ? null
                  : () async {
                      if (await session.canGoForward()) {
                        session.goForward();
                      }
                    },
            ),
            _btn(
              Icons.refresh,
              '刷新',
              session == null ? null : () => session.reload(),
            ),
            // macOS 逃生口：内嵌页输入异常时一键交给系统浏览器。
            if (Platform.isMacOS)
              _btn(
                Icons.open_in_browser,
                '在系统浏览器打开（内嵌页异常时备用）',
                session == null ? null : () => session.openExternal(),
              ),
            _buildPanToggle(),
            // Android：视图复位——双指缩放和字体缩放一起归位，页面回到
            // 刚打开时的整页适配状态（只归双指倍率会残留字体缩放，
            // 排版依然不是初始适配的样子）。
            if (Platform.isAndroid)
              _btn(
                Icons.filter_center_focus,
                '视图复位（回到整页适配）',
                widget.controller == null
                    ? null
                    : () async {
                        await resetNativeZoom(widget.controller);
                        widget.pageZoom.value = 1.0;
                      },
              ),
            // 双指缩放开关：Android 可用（默认关），macOS 置灰（只有
            // 整页缩放，没有字体缩放）。
            if (Platform.isAndroid || Platform.isMacOS) _buildPinchToggle(),
            const _Divider(),
            // 缩放组与双指缩放分离：Android 上是字体缩放（textZoom），
            // +/- 调、百分比复位，只管字体；双指手势缩放与整体的
            // 「视图复位」在平移开关下方的专门按钮。macOS/iOS 是原生整页缩放 pageZoom，
            // Windows 是 CSS 根缩放。
            _zoomGroup(
              notifier: widget.pageZoom,
              step: 0.25,
              zoomInIcon: Icons.zoom_in,
              zoomOutIcon: Icons.zoom_out,
              label: Platform.isAndroid ? '字体缩放' : '页面缩放',
            ),
            const _Divider(),
            _btn(Icons.more_horiz, '更多 / 设置', _showActions),
            _btn(Icons.keyboard_double_arrow_right, '收起为悬浮球', () {
              setState(() => _expanded = false);
              _armIdleTimers();
            }),
          ],
        ),
      ),
    );
  }

  /// 顶部拖拽把手：按住拖动整条工具栏。
  Widget _buildGrip() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanUpdate: _onDragUpdate,
      onPanEnd: _onDragEnd,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Icon(
          Icons.drag_indicator,
          size: widget.compact ? 16 : 20,
          color: Colors.grey,
        ),
      ),
    );
  }

  /// 平移（抓手）开关：开启后按住页面拖动来移动视野，再点关闭。
  Widget _buildPanToggle() {
    final BrowserSession? view = sessionOf(widget.viewKey);
    if (view == null) {
      return _btn(Icons.back_hand_outlined, '平移视野（页面未就绪）', null);
    }
    return ValueListenableBuilder<bool>(
      valueListenable: view.panMode,
      builder: (context, enabled, _) {
        final color = enabled ? Theme.of(context).colorScheme.primary : null;
        return IconButton(
          icon: Icon(
            Icons.back_hand_outlined,
            size: _iconSize,
            color: color,
          ),
          tooltip: enabled ? '关闭平移视野' : '平移视野（按住页面拖动）',
          onPressed: () => view.setPanMode(!enabled),
          visualDensity: VisualDensity.compact,
          style: IconButton.styleFrom(
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            backgroundColor: enabled
                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.15)
                : null,
          ),
        );
      },
    );
  }

  /// 双指缩放开关：Android 触屏双指，默认关闭。macOS 置灰不可点——
  /// WKWebView 只有整页缩放、没有系统级字体缩放（textZoom 是 Android
  /// 独有），触摸板捏合做出来也是整页缩放，按要求不做。
  Widget _buildPinchToggle() {
    if (Platform.isMacOS) {
      return _btn(Icons.pinch, '双指缩放（macOS 不支持字体缩放，不可用）', null);
    }
    final view = sessionOf(widget.viewKey);
    if (view == null) {
      return _btn(Icons.pinch, '双指缩放（页面未就绪）', null);
    }
    return ValueListenableBuilder<bool>(
      valueListenable: view.pinchZoom,
      builder: (context, enabled, _) {
        final color = enabled ? Theme.of(context).colorScheme.primary : null;
        return IconButton(
          icon: Icon(Icons.pinch, size: _iconSize, color: color),
          tooltip: enabled ? '关闭双指缩放' : '双指缩放（双指捏合）',
          onPressed: () => view.setPinchZoom(!enabled),
          visualDensity: VisualDensity.compact,
          style: IconButton.styleFrom(
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            backgroundColor: enabled
                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.15)
                : null,
          ),
        );
      },
    );
  }

  Widget _zoomGroup({
    required ValueNotifier<double> notifier,
    required double step,
    required IconData zoomInIcon,
    required IconData zoomOutIcon,
    required String label,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GlassIconButton(
          icon: zoomInIcon,
          tooltip: '$label · 放大',
          onPressed: () => _setZoom(notifier, notifier.value + step, step),
        ),
        ValueListenableBuilder<double>(
          valueListenable: notifier,
          builder: (context, value, _) => Tooltip(
            message: '$label · 点击回到 100%',
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => _setZoom(notifier, 1.0, step),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                child: Text(
                  '${(value * 100).round()}%',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ),
        GlassIconButton(
          icon: zoomOutIcon,
          tooltip: '$label · 缩小',
          onPressed: () => _setZoom(notifier, notifier.value - step, step),
        ),
      ],
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 0.6,
      width: 28,
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: Theme.of(context).dividerColor.withValues(alpha: 0.4),
    );
  }
}
