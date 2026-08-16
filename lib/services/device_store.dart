import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/remote_device.dart';

/// 设备列表 + 悬浮球偏好，shared_preferences 持久化。
class DeviceStore extends ChangeNotifier {
  static const _kDevices = 'devices_v1';
  static const _kCurrent = 'current_device_id';
  static const _kBubbleEnabled = 'bubble_enabled';
  static const _kToolbarDx = 'toolbar_dx';
  static const _kToolbarDy = 'toolbar_dy';
  static const _kViewZoom = 'view_zoom';
  static const _kDesktopMode = 'desktop_mode';

  List<RemoteDevice> devices = [];
  String? currentId;

  /// 悬浮控制栏（悬浮球+工具栏二合一）是否显示。
  bool bubbleEnabled = true;

  /// 悬浮控制栏位置（0..1 比例），dx 只会吸附到 0 或 1，默认右侧。
  double? toolbarDx;
  double? toolbarDy;

  /// 保存的可视缩放比例：当前会话内刷新后复用，切换会话时重置为 1.0。
  /// （「页面缩放」已移除，历史 page_zoom 键留在本地不再读取。）
  double savedViewZoom = 1.0;

  /// 桌面模式：WebView 用桌面版 UA 请求站点，全局偏好。
  bool desktopMode = false;

  RemoteDevice? get current {
    if (currentId == null) return null;
    for (final d in devices) {
      if (d.id == currentId) return d;
    }
    return null;
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kDevices);
    if (raw != null) {
      try {
        devices = (jsonDecode(raw) as List)
            .map((e) => RemoteDevice.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {}
    }
    currentId = prefs.getString(_kCurrent);
    if (currentId == null && devices.isNotEmpty) {
      currentId = devices.first.id;
    }
    bubbleEnabled = prefs.getBool(_kBubbleEnabled) ?? true;
    toolbarDx = prefs.getDouble(_kToolbarDx);
    toolbarDy = prefs.getDouble(_kToolbarDy);
    savedViewZoom = prefs.getDouble(_kViewZoom) ?? 1.0;
    desktopMode = prefs.getBool(_kDesktopMode) ?? false;
    notifyListeners();
  }

  Future<void> _saveDevices() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kDevices,
      jsonEncode(devices.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> _saveCurrent() async {
    final prefs = await SharedPreferences.getInstance();
    if (currentId != null) {
      await prefs.setString(_kCurrent, currentId!);
    }
  }

  /// 新增设备；同 mid 视为同一台机器，直接替换地址（用户说的"报错了就替换"场景）。
  Future<RemoteDevice> addDevice(String url, {String? remark}) async {
    final trimmed = url.trim();
    final mid = RemoteDevice.midFromUrl(trimmed);
    final id = mid ?? 'd_${DateTime.now().microsecondsSinceEpoch}';
    final cleanRemark = (remark == null || remark.trim().isEmpty)
        ? null
        : remark.trim();
    final now = DateTime.now();

    final idx = devices.indexWhere((d) => d.id == id);
    if (idx >= 0) {
      devices[idx].url = trimmed;
      if (cleanRemark != null) devices[idx].remark = cleanRemark;
      devices[idx].lastOpenedAt = now;
      currentId = id;
      await _saveDevices();
      await _saveCurrent();
      notifyListeners();
      return devices[idx];
    }

    final device = RemoteDevice(
      id: id,
      url: trimmed,
      remark: cleanRemark,
      addedAt: now,
      lastOpenedAt: now,
    );
    devices.insert(0, device);
    currentId = id;
    await _saveDevices();
    await _saveCurrent();
    notifyListeners();
    return device;
  }

  Future<void> updateDevice(String id, {String? url, String? remark}) async {
    final idx = devices.indexWhere((d) => d.id == id);
    if (idx < 0) return;
    if (url != null && url.trim().isNotEmpty) devices[idx].url = url.trim();
    if (remark != null) {
      devices[idx].remark = remark.trim().isEmpty ? null : remark.trim();
    }
    await _saveDevices();
    notifyListeners();
  }

  Future<void> remove(String id) async {
    devices.removeWhere((d) => d.id == id);
    if (currentId == id) {
      currentId = devices.isNotEmpty ? devices.first.id : null;
      await _saveCurrent();
    }
    await _saveDevices();
    notifyListeners();
  }

  Future<void> select(String id) async {
    final idx = devices.indexWhere((d) => d.id == id);
    if (idx < 0) return;
    currentId = id;
    devices[idx].lastOpenedAt = DateTime.now();
    await _saveCurrent();
    await _saveDevices();
    notifyListeners();
  }

  /// 备注为空时，用 WebView 读到的页面标题补上（尽力而为，不覆盖用户手写备注）。
  Future<void> maybeFillRemarkFromTitle(String id, String title) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return;
    final idx = devices.indexWhere((d) => d.id == id);
    if (idx < 0) return;
    if (devices[idx].remark != null && devices[idx].remark!.isNotEmpty) return;
    // URL 里已经能解析出 name 时也不必用标题覆盖。
    if (RemoteDevice.nameFromUrl(devices[idx].url) != null) return;
    devices[idx].remark = trimmed;
    await _saveDevices();
    notifyListeners();
  }

  Future<void> setBubbleEnabled(bool enabled) async {
    bubbleEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kBubbleEnabled, enabled);
    notifyListeners();
  }

  Future<void> setToolbarPosition(double dx, double dy) async {
    toolbarDx = dx;
    toolbarDy = dy;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kToolbarDx, dx);
    await prefs.setDouble(_kToolbarDy, dy);
  }

  /// 记录可视缩放比例（不触发界面通知，纯持久化）。
  Future<void> setZooms(double viewZoom) async {
    savedViewZoom = viewZoom;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kViewZoom, viewZoom);
  }

  Future<void> setDesktopMode(bool enabled) async {
    desktopMode = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kDesktopMode, enabled);
    notifyListeners();
  }

  /// 列表展示名：用户备注 > URL name 参数 > mid 短码 > host。
  String displayName(RemoteDevice device) {
    final remark = device.remark;
    if (remark != null && remark.isNotEmpty) return remark;
    final fromUrl = RemoteDevice.nameFromUrl(device.url);
    if (fromUrl != null) return fromUrl;
    if (!device.id.startsWith('d_') && device.id.length >= 8) {
      return '设备 ${device.id.substring(0, 8)}';
    }
    final host = RemoteDevice.hostFromUrl(device.url);
    return host.isNotEmpty ? host : '未命名设备';
  }

  /// host 脱敏展示（完整 URL 含凭证，不在列表直接展示）。
  String subtitle(RemoteDevice device) {
    final host = RemoteDevice.hostFromUrl(device.url);
    return host.isNotEmpty ? host : device.url;
  }
}
