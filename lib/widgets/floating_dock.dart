import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';

import '../services/device_store.dart';
import 'browser_view.dart';
import 'glass.dart';

/// 悬浮控制栏（悬浮球 + 工具栏二合一）。
///
/// 收起态：圆形玻璃悬浮球（终端图标），点击展开；可整球拖拽、吸附左右
/// 边缘；闲置 3 秒自动吸附到最右侧，累计 5 秒透明度降得更低。
/// 展开态：竖排玻璃工具栏——设备切换、前进/后退/刷新、平移模式、
/// 可视缩放、页面缩放、页面操作菜单（含桌面版网站开关）；
/// 按住顶部把手拖动，位置持久化，展开期间不收起、不淡化。
/// 从设置/面板隐藏后变成贴边细把手，点击恢复。
class FloatingDock extends StatefulWidget {
  const FloatingDock({
    super.key,
    required this.controller,
    required this.viewKey,
    required this.pageZoom,
    required this.viewZoom,
    required this.onReplaceAddress,
    required this.onOpenSwitcher,
    required this.onDesktopModeChanged,
  });

  /// 当前页的 WebView 控制器（无打开会话时为 null）。
  final InAppWebViewController? controller;

  /// 当前 BrowserView 的 key，用于调用复制/分享等页面操作。
  final GlobalKey<BrowserViewState>? viewKey;

  /// 页面缩放（重排布局）。
  final ValueNotifier<double> pageZoom;

  /// 可视缩放（只放大可视范围，不重排）。
  final ValueNotifier<double> viewZoom;

  final VoidCallback onReplaceAddress;

  /// 打开设备切换面板。
  final VoidCallback onOpenSwitcher;

  /// 桌面模式切换后的回调（外部用它重建当前会话使 UA 生效）。
  final VoidCallback onDesktopModeChanged;

  @override
  State<FloatingDock> createState() => _FloatingDockState();
}

class _FloatingDockState extends State<FloatingDock> {
  static const double _bubbleSize = 52;
  static const double _barWidth = 56;
  static const double _minZoom = 0.5;
  static const double _maxZoom = 3.0;

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
  /// 3 秒不动 → 自动吸附到最右侧；累计 5 秒不动 → 透明度降得更低。
  void _armIdleTimers() {
    _snapTimer?.cancel();
    _dimTimer?.cancel();
    if (_expanded) return;
    _snapTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted || _expanded) return;
      setState(() => _dx = 1.0);
      context.read<DeviceStore>().setToolbarPosition(1.0, _dy);
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

  void _showActions() {
    final view = widget.viewKey?.currentState;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        Widget item(IconData icon, String label, VoidCallback? action) {
          return ListTile(
            leading: Icon(icon),
            title: Text(label),
            onTap: action == null
                ? null
                : () {
                    Navigator.of(ctx).pop();
                    action();
                  },
          );
        }

        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: GlassContainer(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
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
                // 桌面版网站：切换 UA，重建当前会话生效。
                Consumer<DeviceStore>(
                  builder: (ctx, store, _) => SwitchListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    secondary: const Icon(Icons.desktop_windows_outlined),
                    title: const Text('桌面版网站'),
                    value: store.desktopMode,
                    onChanged: (v) {
                      Navigator.of(ctx).pop();
                      store.setDesktopMode(v).then((_) {
                        widget.onDesktopModeChanged();
                      });
                    },
                  ),
                ),
                item(Icons.edit_note, '替换此设备地址', widget.onReplaceAddress),
              ],
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
    context.read<DeviceStore>().setToolbarPosition(snapped, _dy);
    _armIdleTimers();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<DeviceStore>();
    if (!_initialized) {
      _dx = store.toolbarDx ?? 1.0; // 默认右边缘
      _dy = store.toolbarDy ?? 0.5;
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
        final estimatedHeight = _expanded ? 530.0 : _bubbleSize;
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
                  borderRadius: _expanded ? 28 : _bubbleSize / 2,
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
          size: 26,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }

  /// 展开态：顶部拖拽把手 + 完整工具栏。
  Widget _buildExpanded() {
    final controller = widget.controller;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildGrip(),
        GlassIconButton(
          icon: Icons.devices_rounded,
          tooltip: '切换设备',
          onPressed: widget.onOpenSwitcher,
        ),
        const _Divider(),
        GlassIconButton(
          icon: Icons.arrow_back_ios_new,
          tooltip: '后退',
          onPressed: controller == null
              ? null
              : () async {
                  if (await controller.canGoBack()) controller.goBack();
                },
        ),
        GlassIconButton(
          icon: Icons.arrow_forward_ios,
          tooltip: '前进',
          onPressed: controller == null
              ? null
              : () async {
                  if (await controller.canGoForward()) controller.goForward();
                },
        ),
        GlassIconButton(
          icon: Icons.refresh,
          tooltip: '刷新',
          onPressed: controller == null ? null : () => controller.reload(),
        ),
        _buildPanToggle(),
        const _Divider(),
        // 可视缩放：只放大可视范围，页面布局不变（放大镜图标）。
        _zoomGroup(
          notifier: widget.viewZoom,
          step: 0.25,
          zoomInIcon: Icons.zoom_in,
          zoomOutIcon: Icons.zoom_out,
          label: '可视缩放（布局不变）',
        ),
        const _Divider(),
        // 页面缩放：页面自身放大缩小，布局重排（字体图标）。
        _zoomGroup(
          notifier: widget.pageZoom,
          step: 0.1,
          zoomInIcon: Icons.text_increase,
          zoomOutIcon: Icons.text_decrease,
          label: '页面缩放（布局重排）',
        ),
        const _Divider(),
        GlassIconButton(
          icon: Icons.more_horiz,
          tooltip: '页面操作',
          onPressed: _showActions,
        ),
        GlassIconButton(
          icon: Icons.keyboard_double_arrow_right,
          tooltip: '收起为悬浮球',
          onPressed: () {
            setState(() => _expanded = false);
            _armIdleTimers();
          },
        ),
      ],
    );
  }

  /// 顶部拖拽把手：按住拖动整条工具栏。
  Widget _buildGrip() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanUpdate: _onDragUpdate,
      onPanEnd: _onDragEnd,
      child: const Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: Icon(Icons.drag_indicator, size: 20, color: Colors.grey),
      ),
    );
  }

  /// 平移（抓手）开关：开启后按住页面拖动来移动视野，再点关闭。
  Widget _buildPanToggle() {
    final view = widget.viewKey?.currentState;
    if (view == null) {
      return const GlassIconButton(
        icon: Icons.back_hand_outlined,
        tooltip: '平移视野（页面未就绪）',
        onPressed: null,
      );
    }
    return ValueListenableBuilder<bool>(
      valueListenable: view.panMode,
      builder: (context, enabled, _) {
        final color = enabled ? Theme.of(context).colorScheme.primary : null;
        return IconButton(
          icon: Icon(Icons.back_hand_outlined, size: 22, color: color),
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
