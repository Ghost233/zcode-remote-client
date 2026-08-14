import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';

import '../models/remote_device.dart';
import '../services/device_store.dart';
import '../widgets/browser_view.dart';
import '../widgets/device_edit_sheet.dart';
import '../widgets/device_switcher_sheet.dart';
import '../widgets/floating_bubble.dart';
import '../widgets/glass.dart';
import '../widgets/glass_toolbar.dart';
import 'settings_page.dart';

/// 首页：全屏浏览器 + 悬浮玻璃工具栏 + 可拖拽悬浮球。
///
/// 多台设备的 WebView 通过 IndexedStack 保活，切换不断连；
/// 移动端整体包在 SafeArea 里，避开刘海/灵动岛和底部手势区。
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final List<String> _openIds = [];
  final Map<String, InAppWebViewController> _controllers = {};
  final Map<String, ValueNotifier<double>> _pageZooms = {};
  final Map<String, ValueNotifier<double>> _viewZooms = {};
  final Map<String, GlobalKey<BrowserViewState>> _viewKeys = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final store = context.read<DeviceStore>();
      final id = store.currentId;
      if (id != null) {
        // 启动时用保存的缩放比例初始化首个会话。
        _open(id,
            initialPageZoom: store.savedPageZoom,
            initialViewZoom: store.savedViewZoom);
      }
    });
  }

  @override
  void dispose() {
    for (final z in _pageZooms.values) {
      z.dispose();
    }
    for (final z in _viewZooms.values) {
      z.dispose();
    }
    super.dispose();
  }

  void _open(String id, {double? initialPageZoom, double? initialViewZoom}) {
    if (!_openIds.contains(id)) {
      setState(() {
        _openIds.add(id);
        _pageZooms[id] = ValueNotifier(initialPageZoom ?? 1.0);
        _viewZooms[id] = ValueNotifier(initialViewZoom ?? 1.0);
        _viewKeys[id] = GlobalKey<BrowserViewState>();
      });
      // 缩放变化时持久化，刷新/重启后可复用。
      _pageZooms[id]!.addListener(_persistZooms);
      _viewZooms[id]!.addListener(_persistZooms);
    }
  }

  void _persistZooms() {
    final store = context.read<DeviceStore>();
    final id = store.currentId;
    if (id == null) return;
    store.setZooms(
      _pageZooms[id]?.value ?? 1.0,
      _viewZooms[id]?.value ?? 1.0,
    );
  }

  Future<void> _selectDevice(RemoteDevice device) async {
    final store = context.read<DeviceStore>();
    final switching = store.currentId != device.id;
    _open(device.id);
    if (switching) {
      // 需求：切到另一个会话时，缩放和平移重置为默认。
      _pageZooms[device.id]?.value = 1.0;
      _viewZooms[device.id]?.value = 1.0;
      final view = _viewKeys[device.id]?.currentState;
      if (view != null && view.panMode.value) view.setPanMode(false);
    }
    await store.select(device.id);
  }

  void _closeSession(RemoteDevice device) {
    setState(() {
      _openIds.remove(device.id);
      _controllers.remove(device.id);
      _pageZooms.remove(device.id)?.dispose();
      _viewZooms.remove(device.id)?.dispose();
      _viewKeys.remove(device.id);
    });
    // 关掉的是当前会话且还有其他会话保活着 → 切到最近打开的那个，
    // 同样按"切换会话"处理：缩放和平移重置。
    final store = context.read<DeviceStore>();
    if (store.currentId == device.id && _openIds.isNotEmpty) {
      final nextId = _openIds.last;
      _pageZooms[nextId]?.value = 1.0;
      _viewZooms[nextId]?.value = 1.0;
      final view = _viewKeys[nextId]?.currentState;
      if (view != null && view.panMode.value) view.setPanMode(false);
      store.select(nextId);
    }
  }

  InAppWebViewController? _currentController(DeviceStore store) {
    final id = store.currentId;
    if (id == null || !_openIds.contains(id)) return null;
    return _controllers[id];
  }

  Future<void> _onSystemBack() async {
    final store = context.read<DeviceStore>();
    final controller = _currentController(store);
    if (controller != null && await controller.canGoBack()) {
      await controller.goBack();
    } else {
      await SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<DeviceStore>();
    final currentId = store.currentId;
    final currentIndex =
        currentId != null ? _openIds.indexOf(currentId) : -1;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onSystemBack();
      },
      child: Scaffold(
        // 键盘弹出时整体收缩，工具栏随之浮到键盘上方。
        resizeToAvoidBottomInset: true,
        body: SafeArea(
          child: Stack(
            children: [
              // 网页层：各设备会话保活
              if (_openIds.isNotEmpty)
                IndexedStack(
                  index: currentIndex >= 0 ? currentIndex : 0,
                  children: [
                    for (final id in _openIds)
                      _buildBrowser(store, id),
                  ],
                )
              else
                _buildEmptyState(store),

              // 悬浮玻璃工具栏：默认右边缘，可拖动吸附两侧
              Positioned.fill(
                child: GlassToolbar(
                  controller: _currentController(store),
                  viewKey:
                      currentId != null ? _viewKeys[currentId] : null,
                  pageZoom:
                      currentId != null && _pageZooms.containsKey(currentId)
                          ? _pageZooms[currentId]!
                          : ValueNotifier(1.0),
                  viewZoom:
                      currentId != null && _viewZooms.containsKey(currentId)
                          ? _viewZooms[currentId]!
                          : ValueNotifier(1.0),
                  onReplaceAddress: () {
                    final device = store.current;
                    if (device != null) {
                      DeviceEditSheet.show(context, editing: device);
                    }
                  },
                ),
              ),

              // 可拖拽悬浮球（恒在最上层）
              Positioned.fill(
                child: FloatingBubble(
                  onTap: () => DeviceSwitcherSheet.show(
                    context,
                    openIds: _openIds.toSet(),
                    onSelect: _selectDevice,
                    onCloseSession: _closeSession,
                    onOpenSettings: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const SettingsPage()),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBrowser(DeviceStore store, String id) {
    RemoteDevice? device;
    for (final d in store.devices) {
      if (d.id == id) device = d;
    }
    if (device == null) {
      // 设备已被删除但会话还开着 → 直接移除。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _openIds.contains(id)) {
          setState(() {
            _openIds.remove(id);
            _controllers.remove(id);
            _pageZooms.remove(id)?.dispose();
            _viewZooms.remove(id)?.dispose();
            _viewKeys.remove(id);
          });
        }
      });
      return const SizedBox.shrink();
    }
    return BrowserView(
      key: _viewKeys[id],
      device: device,
      pageZoom: _pageZooms[id]!,
      viewZoom: _viewZooms[id]!,
      onControllerReady: (controller) {
        _controllers[id] = controller;
        // controller 就绪后必须重建一次，否则工具栏的导航/刷新按钮
        // 会一直拿着 null controller 处于禁用态。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() {});
        });
      },
      onTitleChanged: (title) =>
          context.read<DeviceStore>().maybeFillRemarkFromTitle(id, title),
      onReplaceAddress: () =>
          DeviceEditSheet.show(context, editing: device),
    );
  }

  Widget _buildEmptyState(DeviceStore store) {
    final hasDevices = store.devices.isNotEmpty;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: GlassContainer(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.terminal_rounded,
                  size: 52, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 16),
              Text('ZCode 远程客户端',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                hasDevices
                    ? '所有会话都已关闭\n点击悬浮球重新选择设备'
                    : '还没有保存任何远程地址\n添加一个 ZCode 远程连接开始使用',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 20),
              if (!hasDevices)
                FilledButton.icon(
                  onPressed: () => DeviceEditSheet.show(context),
                  icon: const Icon(Icons.add_link),
                  label: const Text('添加远程地址'),
                )
              else
                FilledButton.icon(
                  onPressed: () {
                    final id = store.currentId;
                    if (id != null) _open(id);
                  },
                  icon: const Icon(Icons.refresh),
                  label: const Text('重新打开当前设备'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
