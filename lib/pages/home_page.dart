

import 'dart:io' show Platform;

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';

import '../models/remote_device.dart';
import '../services/device_store.dart';
import '../services/download_manager.dart';
import '../services/keep_alive.dart';
import '../widgets/browser_session.dart';
import '../widgets/browser_view.dart';
import '../widgets/device_edit_sheet.dart';
import '../widgets/device_switcher_sheet.dart';
import '../widgets/floating_dock.dart';
import '../widgets/glass.dart';
import '../widgets/session_tab_bar.dart';
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

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final List<String> _openIds = [];
  final Map<String, InAppWebViewController> _controllers = {};
  final Map<String, ValueNotifier<double>> _pageZooms = {};
  final Map<String, GlobalKey> _viewKeys = {};

  /// 当前会话的页面实际背景色（从网页读取）。Android 上 SafeArea 露出
  /// 的区域刷成这个颜色（默认近黑，贴合 zcode 深色界面），状态栏图标
  /// 亮暗也随它走。
  final ValueNotifier<Color> _pageBg =
      ValueNotifier(const Color(0xFF171717));

  /// 左右分屏开关。开启后左右窗格顶部各自带页签栏：左窗格显示当前
  /// 会话，右窗格显示 [_splitRightId]（未显式指定时取另一个打开的
  /// 会话）。同一个 WebView 不能同时挂两个窗格，所以任何时候两
  /// 窗格显示的会话都不同（点/拖对方窗格正在显示的页签 = 两侧互换）。
  bool _splitOn = false;

  /// 分屏右窗格显式指定的会话 id（null = 由 fallback 取另一个打开的
  /// 会话）。分屏时两侧都是保活的现有会话，不重连。
  String? _splitRightId;

  /// 左侧窗格宽度占比（拖动分隔条更新），默认对半。
  double _splitFraction = 0.5;

  /// 是否已做过启动自动恢复（只恢复一次，之后由用户操作驱动）。
  bool _autoOpened = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkUpdatesOnStart();
    // 下载结束后若人还在后台且用户没开保活：撤掉为下载临时挂的前台
    // 服务，不留一条名不副实的常驻通知（开了保活则继续挂着护会话）。
    DownloadManager.instance.status.addListener(_onDownloadStatusChanged);
  }

  void _onDownloadStatusChanged() {
    final s = DownloadManager.instance.status.value;
    if (s == DownloadStatus.downloading) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final inBackground = lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.hidden;
    if (inBackground && !context.read<DeviceStore>().keepAliveEnabled) {
      BackgroundKeepAlive.stop();
    }
  }

  /// 后台保活：退后台挂前台服务保持 ZCode 会话连接（Android、可关），
  /// 回前台撤掉。避免回来时 WebSocket 已断、页面整页刷新重连。
  /// 例外：更新包正在下载时无视开关一定挂——下载连接不能因切后台被
  /// 系统掐断（下载结束后按上面的监听决定撤不撤）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final store = context.read<DeviceStore>();
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        final downloading =
            DownloadManager.instance.status.value == DownloadStatus.downloading;
        if (downloading) {
          BackgroundKeepAlive.start(text: '正在后台下载更新，请保持后台运行');
        } else if (store.keepAliveEnabled) {
          BackgroundKeepAlive.start();
        }
      case AppLifecycleState.resumed:
        BackgroundKeepAlive.stop();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  Future<void> _checkUpdatesOnStart() async {
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    // 启动静默检查更新：断点自动续传/已就绪只走通知栏，不打扰；
    // 全新版本才弹「发现新版本」引导。详见 update_dialog.dart。
    checkForUpdates(context);
  }

  @override
  void dispose() {
    DownloadManager.instance.status.removeListener(_onDownloadStatusChanged);
    WidgetsBinding.instance.removeObserver(this);
    for (final z in _pageZooms.values) {
      z.dispose();
    }
    _pageBg.dispose();
    super.dispose();
  }

  void _open(String id) {
    if (!_openIds.contains(id)) {
      setState(() {
        _openIds.add(id);
        // 缩放默认 1.0：切 tab 期间各自的缩放保留在内存里，但应用
        // 重启后不恢复（需求：重启即回到默认适配状态）。
        _pageZooms[id] = ValueNotifier(1.0);
        _viewKeys[id] = GlobalKey();
      });
    }
  }

  Future<void> _selectDevice(RemoteDevice device) async {
    final store = context.read<DeviceStore>();
    final switching = store.currentId != device.id;
    _open(device.id);
    if (switching) {
      // 切会话保留各自的缩放（双指缩放是 WebView 自身状态，本来就
      // 跟着会话走）；只收起平移模式，避免抓手模式跨会话误操作。
      final session = sessionOf(_viewKeys[device.id]);
      if (session != null && session.panMode.value) {
        session.setPanMode(false);
      }
    }
    await store.select(device.id);
  }

  void _closeSession(RemoteDevice device) {
    setState(() {
      _openIds.remove(device.id);
      _controllers.remove(device.id);
      _pageZooms.remove(device.id)?.dispose();
      _viewKeys.remove(device.id);
      // 右窗格会话被关：清空显式指定，由 fallback 顶上来继续分屏
      if (_splitRightId == device.id) _splitRightId = null;
      // 不够两个会话了：退出分屏
      if (_openIds.length < 2) _splitOn = false;
    });
    // 关掉的是当前会话且还有其他会话保活着 → 切到最近打开的那个，
    // 保留其缩放，只收起平移模式。
    final store = context.read<DeviceStore>();
    if (store.currentId == device.id && _openIds.isNotEmpty) {
      // 后补会话不能是右窗格正在显示的那个（同一个 WebView 不能
      // 同时挂在两个窗格里）。
      final nextId = _openIds.lastWhere(
        (id) => id != _splitRightId,
        orElse: () => _openIds.last,
      );
      final session = sessionOf(_viewKeys[nextId]);
      if (session != null && session.panMode.value) {
        session.setPanMode(false);
      }
      store.select(nextId);
    }
  }

  InAppWebViewController? _currentController(DeviceStore store) {
    final id = store.currentId;
    if (id == null || !_openIds.contains(id)) return null;
    return _controllers[id];
  }

  /// 分屏右侧显示的会话：优先用显式选的，否则默认取另一个打开的会话。
  String? _effectiveSplitRight(String? currentId) {
    if (currentId == null || !_openIds.contains(currentId)) return null;
    final right = _splitRightId;
    if (right != null && right != currentId && _openIds.contains(right)) {
      return right;
    }
    for (final id in _openIds) {
      if (id != currentId) return id;
    }
    return null;
  }

  void _toggleSplit(DeviceStore store) {
    setState(() {
      if (_splitOn) {
        _splitOn = false;
      } else {
        _splitRightId = _effectiveSplitRight(store.currentId);
        _splitOn = _splitRightId != null;
      }
    });
  }

  /// 分屏模式下让某个窗格显示会话 [id]（right=false 为左窗格）。
  /// [id] 正显示在另一个窗格时两侧互换；别的窗格不受影响。
  Future<void> _showInPane(String id, {required bool right}) async {
    if (!_openIds.contains(id)) return;
    final store = context.read<DeviceStore>();
    if (!store.devices.any((d) => d.id == id)) return;
    final leftId = store.currentId;
    final rightId = _effectiveSplitRight(leftId);
    if (right) {
      if (rightId == null || id == rightId) return; // 已在右窗格
      // 右窗格改显示 id；若 id 是左窗格当前页，左窗格改显示原右侧
      final newLeft = (id == leftId) ? rightId : leftId;
      setState(() => _splitRightId = id);
      if (newLeft != null && newLeft != leftId) {
        final session = sessionOf(_viewKeys[newLeft]);
        if (session != null && session.panMode.value) {
          session.setPanMode(false);
        }
        await store.select(newLeft);
      }
    } else {
      if (id == leftId) return; // 已在左窗格
      // 左窗格改显示 id；若 id 是右窗格当前页，右窗格改显示原左侧
      final newRight = (id == rightId) ? leftId : rightId;
      final session = sessionOf(_viewKeys[id]);
      if (session != null && session.panMode.value) {
        session.setPanMode(false);
      }
      await store.select(id);
      if (!mounted) return;
      setState(() => _splitRightId = newRight);
    }
  }

  /// 分屏模式下从「+」面板选设备进指定窗格：没打开的会话先正常
  /// 打开（默认进左窗格成为当前会话），目标是右窗格再挪过去。
  Future<void> _openInPane(RemoteDevice device, {required bool right}) async {
    if (_openIds.contains(device.id)) {
      await _showInPane(device.id, right: right);
      return;
    }
    await _selectDevice(device);
    if (!mounted || !right) return;
    await _showInPane(device.id, right: true);
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

  /// 桌面模式切换后重建指定会话：换新 GlobalKey 强制 WebView 重新创建，
  /// 使新的 User-Agent 生效（UA 无法对已有 WebView 动态回退），缩放比例保留。
  void _recreateSession(String id) {
    if (!_openIds.contains(id)) return;
    setState(() {
      _controllers.remove(id);
      _viewKeys[id] = GlobalKey();
    });
  }

  /// 桌面模式切换后重建当前会话（单屏悬浮球用；分屏窗格的小球重建
  /// 各自窗格的会话，见 _buildSplitPaneSide）。
  void _recreateCurrentSession() {
    final store = context.read<DeviceStore>();
    final id = store.currentId;
    if (id != null) _recreateSession(id);
  }

  SystemUiOverlayStyle _systemOverlayStyle(Brightness brightness) {
    // 深浅判定优先跟页面实际背景色（近黑页面配浅色图标），没有页面
    // 数据时退回系统主题。
    final bgLuminance = _pageBg.value.computeLuminance();
    final dark =
        _openIds.isNotEmpty ? bgLuminance < 0.5 : brightness == Brightness.dark;
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

    // 响应式自动打开：设备列表是异步加载的，可能晚于首帧——一次性检查会
    // 永远停在空状态。只在"尚未打开过任何会话"时自动恢复，避免用户
    // 主动关闭全部会话后又被强行拉起。
    if (currentId != null && _openIds.isEmpty && !_autoOpened) {
      _autoOpened = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _open(currentId);
      });
    }

    // 安全区策略（v1.4.5 起）：
    // - iOS：网页层完全铺满，WKWebView 原生自动内缩（AUTOMATIC），
    //   内容避让刘海/Home Indicator，背景延伸到全屏（Safari 同款）
    // - Android：SafeArea 裁出安全区（页面视口=可视区，100% 布局不会再
    //   溢出屏幕），露出区域刷成页面实际背景色（WebView 里读出来的），
    //   不会再露白；状态栏图标亮暗也跟背景色走
    // （曾试过给网页注入安全区 padding 的方案：与页面自身 100vh 满高
    //  布局冲突，底部内容被挤出屏幕，废弃。）
    final webLayer = ValueListenableBuilder(
      valueListenable: _pageBg,
      builder: (context, Color bg, _) => ColoredBox(
        color: Platform.isAndroid ? bg : Colors.transparent,
        child: _openIds.isNotEmpty
            ? IndexedStack(
                index: currentIndex >= 0 ? currentIndex : 0,
                children: [
                  for (final id in _openIds) _buildBrowser(store, id),
                ],
              )
            : _buildEmptyState(store),
      ),
    );

    // 分屏状态：右窗格会话（显式指定或 fallback 取另一个打开的会话）。
    final rightId = _splitOn ? _effectiveSplitRight(currentId) : null;
    final splitOn = rightId != null && currentId != null;

    // 顶栏会话页签：浏览器风格的 tab 条，仅单屏时显示（分屏后每个
    // 窗格顶部自带一条，见 _buildSplitPaneSide）。Android 上放在
    // SafeArea 内、网页层之上（竖向占位，不遮内容）；iOS 上悬浮在
    // 安全区内顶部。
    final tabBar = (_openIds.isNotEmpty && !splitOn)
        ? SessionTabBar(
            tabs: [
              for (final id in _openIds)
                SessionTab(id: id, label: _tabLabel(store, id)),
            ],
            activeId: currentId,
            onSelect: (id) {
              final device = store.devices.firstWhereOrNull((d) => d.id == id);
              if (device != null) _selectDevice(device);
            },
            onClose: (id) {
              final device = store.devices.firstWhereOrNull((d) => d.id == id);
              if (device != null) _closeSession(device);
            },
            onAdd: () => DeviceSwitcherSheet.show(
              context,
              openIds: _openIds.toSet(),
              onSelect: _selectDevice,
              onCloseSession: _closeSession,
              onOpenSettings: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsPage()),
                );
              },
            ),
            onRefresh: () {
              final id = store.currentId;
              if (id != null) _controllers[id]?.reload();
            },
            splitActive: _splitOn,
            splitEnabled: _openIds.length >= 2,
            onToggleSplit: () => _toggleSplit(store),
          )
        : null;

    // 分屏布局：左右窗格各自带页签栏，中间分隔条可拖动调整。
    final Widget? splitPane;
    if (splitOn) {
      splitPane = LayoutBuilder(
        builder: (context, constraints) {
          const dividerWidth = 10.0;
          final total = constraints.maxWidth;
          final leftW = (total * _splitFraction).clamp(120.0, total - 120.0);
          return Row(
            children: [
              SizedBox(
                width: leftW,
                child: _buildSplitPaneSide(store, currentId, right: false),
              ),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (d) {
                  setState(() {
                    _splitFraction =
                        ((_splitFraction * total + d.delta.dx) / total)
                            .clamp(0.15, 0.85);
                  });
                },
                child: SizedBox(
                  width: dividerWidth,
                  child: Center(
                    child: Container(
                      width: 3,
                      decoration: BoxDecoration(
                        color: Theme.of(context).dividerColor,
                        borderRadius: BorderRadius.circular(1.5),
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(child: _buildSplitPaneSide(store, rightId, right: true)),
            ],
          );
        },
      );
    } else {
      splitPane = null;
    }

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
              // 网页层：各设备会话保活。分屏开启时替换为左右分栏布局
              // （此时没有全局 tab 栏，各窗格顶部自带页签栏）。
              // - Android：避让安全区，tab 栏在安全区内竖向占位
              // - macOS / Windows：tab 栏竖向占位（悬浮叠放会压住网页
              //   顶部内容——桌面网页普遍把顶栏固定在视口最顶端）
              // - iOS：网页全屏原生内缩，tab 栏悬浮在安全区顶部（见下）
              if (Platform.isAndroid)
                SafeArea(
                  child: tabBar != null
                      ? Column(
                          children: [
                            tabBar,
                            Expanded(child: splitPane ?? webLayer),
                          ],
                        )
                      : (splitPane ?? webLayer),
                )
              else if (Platform.isMacOS || Platform.isWindows)
                tabBar != null
                    ? Column(
                        children: [
                          tabBar,
                          Expanded(child: splitPane ?? webLayer),
                        ],
                      )
                    : (splitPane ?? webLayer)
              else
                // iOS 分屏：窗格页签栏要避开状态栏/刘海，包一层仅顶部
                // 的 SafeArea；底部仍交给 WKWebView 原生内缩，避免双重内缩。
                splitPane != null
                    ? SafeArea(
                        top: true,
                        bottom: false,
                        left: false,
                        right: false,
                        child: splitPane,
                      )
                    : webLayer,

              // iOS：tab 条悬浮在安全区顶部，网页层保持全屏原生内缩
              if (tabBar != null && Platform.isIOS)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: SafeArea(
                    top: true,
                    bottom: false,
                    left: false,
                    right: false,
                    child: tabBar,
                  ),
                ),

              // 悬浮控制栏（悬浮球+工具栏二合一）：默认右边缘收起为球，
              // 点击展开；可拖动吸附两侧，位置持久化；始终避让系统栏。
              // 分屏时这个全屏球隐藏，改为每个窗格各挂一个小号球
              // （见 _buildSplitPaneSide），各管各的会话。
              if (splitPane == null)
              Positioned.fill(
                child: SafeArea(
                  child: FloatingDock(
                    controller: _currentController(store),
                    viewKey: currentId != null ? _viewKeys[currentId] : null,
                    pageZoom:
                        currentId != null && _pageZooms.containsKey(currentId)
                        ? _pageZooms[currentId]!
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
                    onOpenSettings: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const SettingsPage()),
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

  /// 分屏的单个窗格：顶部是自己的页签栏（点页签切换本窗格显示的
  /// 会话，刷新/「+」/关闭也是各管各的窗格），下面是浏览器，浏览器
  /// 上叠一个本窗格专属的小号悬浮球（只控制本窗格会话，位置不持久化，
  /// 闲置吸附到本窗格的外侧边缘）。整个窗格是页签拖放目标——把页签
  /// 拖进来松手即让本窗格改显示它。
  Widget _buildSplitPaneSide(
    DeviceStore store,
    String paneActiveId, {
    required bool right,
  }) {
    return DragTarget<String>(
      onAcceptWithDetails: (d) => _showInPane(d.data, right: right),
      builder: (context, candidate, rejected) {
        final hovering = candidate.isNotEmpty;
        return ColoredBox(
          color: hovering
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.08)
              : Colors.transparent,
          child: Stack(
            children: [
              Column(
                children: [
                  SessionTabBar(
                    tabs: [
                      for (final id in _openIds)
                        SessionTab(id: id, label: _tabLabel(store, id)),
                    ],
                    activeId: paneActiveId,
                    onSelect: (id) => _showInPane(id, right: right),
                    onClose: (id) {
                      final device =
                          store.devices.firstWhereOrNull((d) => d.id == id);
                      if (device != null) _closeSession(device);
                    },
                    onAdd: () => DeviceSwitcherSheet.show(
                      context,
                      openIds: _openIds.toSet(),
                      onSelect: (device) => _openInPane(device, right: right),
                      onCloseSession: _closeSession,
                      onOpenSettings: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const SettingsPage(),
                          ),
                        );
                      },
                    ),
                    onRefresh: () => _controllers[paneActiveId]?.reload(),
                    splitActive: true,
                    splitEnabled: true,
                    onToggleSplit: () => _toggleSplit(store),
                  ),
                  Expanded(child: _buildBrowser(store, paneActiveId)),
                ],
              ),
              // 本窗格的小号悬浮球。只避让底部系统栏：Android 外层已有
              // SafeArea（此处无内边距，是空操作）；iOS 分屏只处理了
              // 顶部，这里把底部 Home 指示条让出来。
              Positioned.fill(
                child: SafeArea(
                  top: false,
                  left: false,
                  right: false,
                  child: FloatingDock(
                    controller: _controllers[paneActiveId],
                    viewKey: _viewKeys[paneActiveId],
                    pageZoom: _pageZooms[paneActiveId]!,
                    compact: true,
                    persistPosition: false,
                    initialDx: right ? 1.0 : 0.0,
                    onReplaceAddress: () {
                      final device = store.devices
                          .firstWhereOrNull((d) => d.id == paneActiveId);
                      if (device != null) {
                        DeviceEditSheet.show(context, editing: device);
                      }
                    },
                    onOpenSwitcher: () => DeviceSwitcherSheet.show(
                      context,
                      openIds: _openIds.toSet(),
                      onSelect: (device) => _openInPane(device, right: right),
                      onCloseSession: _closeSession,
                      onOpenSettings: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const SettingsPage(),
                          ),
                        );
                      },
                    ),
                    onDesktopModeChanged: () =>
                        _recreateSession(paneActiveId),
                    onOpenSettings: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const SettingsPage()),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        );
      },
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
            _viewKeys.remove(id);
            if (_splitRightId == id) _splitRightId = null;
            if (_openIds.length < 2) _splitOn = false;
          });
        }
      });
      return const SizedBox.shrink();
    }
    return BrowserView(
      key: _viewKeys[id],
      device: device,
      pageZoom: _pageZooms[id]!,
      pageBackground: _pageBg,
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

  /// 页签标题：备注优先，没有备注用 URL 主机名兜底（URL 含凭证，
  /// 绝不能整串上屏）。
  String _tabLabel(DeviceStore store, String id) {
    final device = store.devices.firstWhereOrNull((d) => d.id == id);
    final remark = device?.remark;
    if (remark != null && remark.isNotEmpty) return remark;
    final url = device?.url ?? '';
    final host = Uri.tryParse(url)?.host;
    return (host != null && host.isNotEmpty) ? host : '会话';
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
