import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';

import '../services/device_store.dart';
import 'browser_view.dart';
import 'glass.dart';

/// 悬浮玻璃工具栏：竖排，默认停靠屏幕右边缘，按住顶部把手可拖动，
/// 松手自动吸附到左右边缘。包含导航、可视缩放、页面缩放和页面操作菜单。
/// 可折叠成一个小把手。
class GlassToolbar extends StatefulWidget {
  const GlassToolbar({
    super.key,
    required this.controller,
    required this.viewKey,
    required this.pageZoom,
    required this.viewZoom,
    required this.onReplaceAddress,
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

  @override
  State<GlassToolbar> createState() => _GlassToolbarState();
}

class _GlassToolbarState extends State<GlassToolbar> {
  bool _expanded = true;

  // 位置（0..1 比例），dx 吸附后只会是 0 或 1；默认右侧中部。
  double? _dx;
  double _dy = 0.5;
  bool _initialized = false;

  /// 工具栏自身的 key，拖拽时用它量真实尺寸。
  final GlobalKey _toolbarKey = GlobalKey();
  double _containerW = 0;
  double _containerH = 0;

  static const double _minZoom = 0.5;
  static const double _maxZoom = 3.0;

  void _setZoom(ValueNotifier<double> notifier, double v, double step) {
    final snapped = (v / step).round() * step;
    notifier.value =
        double.parse(snapped.toStringAsFixed(2)).clamp(_minZoom, _maxZoom);
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
                item(Icons.link, '复制页面链接',
                    view == null ? null : () => view.copyPageLink()),
                item(Icons.ios_share, '分享当前页面',
                    view == null ? null : () => view.sharePage()),
                item(Icons.copy_all, '复制页面全部文本',
                    view == null ? null : () => view.copyAllText()),
                item(Icons.open_in_new, '在系统浏览器中打开',
                    view == null ? null : () => view.openExternal()),
                item(Icons.refresh, '重新加载',
                    view == null ? null : () => view.reload()),
                item(Icons.edit_note, '替换此设备地址', widget.onReplaceAddress),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<DeviceStore>();
    if (!_initialized) {
      _dx = store.toolbarDx ?? 1.0; // 默认右边缘
      _dy = store.toolbarDy ?? 0.5;
      _initialized = true;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        _containerW = constraints.maxWidth;
        _containerH = constraints.maxHeight;
        // 折叠态尺寸小，展开态按内容实际高度；用估算高度做边界钳制。
        const width = 56.0;
        final estimatedHeight = _expanded ? 470.0 : 60.0;
        final maxX = (constraints.maxWidth - width).clamp(0.0, double.infinity);
        final maxY = (constraints.maxHeight - estimatedHeight)
            .clamp(0.0, double.infinity);
        final x = (_dx! * maxX).clamp(0.0, maxX);
        final y = (_dy * maxY).clamp(0.0, maxY);

        return Stack(
          children: [
            Positioned(
              left: x,
              top: y,
              child: GlassContainer(
                key: _toolbarKey,
                borderRadius: 28,
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                child: _expanded ? _buildExpanded() : _buildCollapsed(),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 顶部拖拽把手：按住拖动整条工具栏。
  Widget _buildGrip() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanUpdate: (details) {
        final box =
            _toolbarKey.currentContext?.findRenderObject() as RenderBox?;
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
      },
      onPanEnd: (_) {
        final snapped = _dx! < 0.5 ? 0.0 : 1.0;
        setState(() => _dx = snapped);
        context.read<DeviceStore>().setToolbarPosition(snapped, _dy);
      },
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
        final color =
            enabled ? Theme.of(context).colorScheme.primary : null;
        return IconButton(
          icon: Icon(Icons.back_hand_outlined, size: 22, color: color),
          tooltip: enabled ? '关闭平移视野' : '平移视野（按住页面拖动）',
          onPressed: () => view.setPanMode(!enabled),
          visualDensity: VisualDensity.compact,
          style: IconButton.styleFrom(
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            backgroundColor: enabled
                ? Theme.of(context)
                    .colorScheme
                    .primary
                    .withValues(alpha: 0.15)
                : null,
          ),
        );
      },
    );
  }

  Widget _buildCollapsed() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildGrip(),
        GlassIconButton(
          icon: Icons.keyboard_arrow_up,
          tooltip: '展开工具栏',
          onPressed: () => setState(() => _expanded = true),
        ),
      ],
    );
  }

  Widget _buildExpanded() {
    final controller = widget.controller;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildGrip(),
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
          icon: Icons.keyboard_arrow_down,
          tooltip: '收起工具栏',
          onPressed: () => setState(() => _expanded = false),
        ),
      ],
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                child: Text(
                  '${(value * 100).round()}%',
                  style: const TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w600),
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
