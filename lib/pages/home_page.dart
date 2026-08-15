import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';

import '../models/remote_device.dart';
import '../services/device_store.dart';
import '../widgets/browser_view.dart';
import '../widgets/device_edit_sheet.dart';
import '../widgets/device_switcher_sheet.dart';
import '../widgets/floating_dock.dart';
import '../widgets/glass.dart';
import '../widgets/update_dialog.dart';
import 'settings_page.dart';

/// 首页：全屏浏览器 + 悬浮控制栏。
///
/// 多台设备的 WebView 通过 IndexedStack 保活，切换不断连。
/// 系统栏避让策略：iOS 网页层整体包 SafeArea 避开刘海/灵动岛和底部
/// 手势区；Android edge-to-edge 下网页完全铺满（状态栏/手势条悬浮其上，
/// 消除顶部留白），悬浮控制栏自身始终避让系统栏。
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
        _open(
          id,
          initialPageZoom: store.savedPageZoom,
          initialViewZoom: store.savedViewZoom,
        );
      }
      // 启动时静默检查更新，发现新版本才弹窗。
      checkForUpdates(context);
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
    store.setZooms(_pageZooms[id]?.value ?? 1.0, _viewZooms[id]?.value ?? 1.0);
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

  /// 桌面模式切换后重建当前会话：换新 GlobalKey 强制 WebView 重新创建，
  /// 使新的 User-Agent 生效（UA 无法对已有 WebView 动态回退），缩放比例保留。
  void _recreateCurrentSession() {
    final store = context.read<DeviceStore>();
    final id = store.currentId;
    if (id == null || !_openIds.contains(id)) return;
    setState(() {
      _controllers.remove(id);
      _viewKeys[id] = GlobalKey<BrowserViewState>();
    });
  }

  SystemUiOverlayStyle _systemOverlayStyle(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      // Android 状态栏图标颜色
      statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
      // iOS 状态栏前景
      statusBarBrightness: dark ? Brightness.dark : Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarContrastEnforced: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<DeviceStore>();
    final currentId = store.currentId;
    final currentIndex = currentId != null ? _openIds.indexOf(currentId) : -1;

    // Android edge-to-edge：网页层完全铺满，不做系统栏避让（否则状态栏
    // 区域会显出一条留白）；iOS 保持避让刘海/灵动岛与底部手势区。
    final webSafeArea = !Platform.isAndroid;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onSystemBack();
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: _systemOverlayStyle(Theme.of(context).brightness),
        child: Scaffold(
          // 键盘弹出时整体收缩，控制栏随之浮到键盘上方。
          resizeToAvoidBottomInset: true,
          body: Stack(
            children: [
              // 网页层：各设备会话保活
              SafeArea(
                top: webSafeArea,
                bottom: webSafeArea,
                left: webSafeArea,
                right: webSafeArea,
                child: _openIds.isNotEmpty
                    ? IndexedStack(
                        index: currentIndex >= 0 ? currentIndex : 0,
                        children: [
                          for (final id in _openIds) _buildBrowser(store, id),
                        ],
                      )
                    : _buildEmptyState(store),
              ),

              // 悬浮控制栏（悬浮球+工具栏二合一）：默认右边缘收起为球，
              // 点击展开；可拖动吸附两侧，位置持久化；始终避让系统栏。
              Positioned.fill(
                child: SafeArea(
                  child: FloatingDock(
                    controller: _currentController(store),
                    viewKey: currentId != null ? _viewKeys[currentId] : null,
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
                    onOpenSwitcher: () => DeviceSwitcherSheet.show(
                      context,
                      openIds: _openIds.toSet(),
                      onSelect: _selectDevice,
                      onCloseSession: _closeSession,
                      onOpenSettings: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const SettingsPage(),
                          ),
                        );
                      },
                    ),
                    onDesktopModeChanged: _recreateCurrentSession,
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
      onReplaceAddress: () => DeviceEditSheet.show(context, editing: device),
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
              Icon(
                Icons.terminal_rounded,
                size: 52,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                'ZCode 远程客户端',
                style: Theme.of(context).textTheme.titleLarge,
              ),
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
