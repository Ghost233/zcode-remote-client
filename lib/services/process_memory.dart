import 'dart:ffi';
import 'dart:io' show File, Platform, Process, pid;

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

/// 进程内存占用查询（设置页展示用，也用于排查内存泄漏）。
///
/// 口径尽量对齐系统设置里看到的数字：
/// - Android：原生把**同 UID 全部进程**的 RSS 加总——WebView 的渲染
///   进程是独立进程，只看主进程会严重低估。通道 `app/memory`
///   （MainActivity.kt 实现）。
/// - macOS：`ps` 取本进程 RSS（WKWebView 渲染在主进程内）。
/// - Windows：FFI GetProcessMemoryInfo 取工作集（WebView2 的子进程
///   不在内，仅供趋势观察）。
/// - 其余（iOS）：尝试 /proc（不可用则返回 null）。
class ProcessMemory {
  ProcessMemory._();

  static const _channel = MethodChannel('app/memory');

  /// 当前应用占用内存（字节，RSS 口径），取不到返回 null。
  static Future<int?> rssBytes() async {
    try {
      if (Platform.isAndroid) {
        final v = await _channel.invokeMethod<int>('rss');
        return v == null ? null : v * 1024; // 原生返回 KB
      }
      if (Platform.isMacOS) {
        final res = Process.runSync('ps', ['-o', 'rss=', '-p', '$pid']);
        if (res.exitCode == 0) {
          final kb = int.tryParse((res.stdout as String).trim());
          if (kb != null && kb > 0) return kb * 1024;
        }
        return null;
      }
      if (Platform.isWindows) return _windowsWorkingSet();
      // iOS / 其他：/proc 不可用，返回 null（调用方显示「不可用」）。
      return _procSelfRss();
    } catch (_) {
      return null;
    }
  }

  /// Linux：读 /proc/self/status 的 VmRSS（KB）。
  static Future<int?> _procSelfRss() async {
    try {
      final lines = await File('/proc/self/status').readAsLines();
      for (final l in lines) {
        if (l.startsWith('VmRSS:')) {
          final kb = int.tryParse(
            l.substring(5).trim().split(' ').first.replaceAll(RegExp(r'\D'), ''),
          );
          if (kb != null && kb > 0) return kb * 1024;
        }
      }
    } catch (_) {}
    return null;
  }

  // ---------- Windows FFI ----------

  static int? _windowsWorkingSet() {
    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final psapi = DynamicLibrary.open('psapi.dll');
      final getCurrentProcess = kernel32.lookupFunction<
          IntPtr Function(),
          int Function()>('GetCurrentProcess');
      final getProcessMemoryInfo = psapi.lookupFunction<
          Int32 Function(IntPtr, Pointer<ProcessMemoryCounters>, Uint32),
          int Function(int, Pointer<ProcessMemoryCounters>, int)>(
          'GetProcessMemoryInfo');
      final counters = calloc<ProcessMemoryCounters>();
      try {
        counters.ref.cb = sizeOf<ProcessMemoryCounters>();
        final handle = getCurrentProcess();
        if (getProcessMemoryInfo(handle, counters, counters.ref.cb) != 0) {
          return counters.ref.workingSetSize;
        }
        return null;
      } finally {
        calloc.free(counters);
      }
    } catch (_) {
      return null;
    }
  }
}

/// psapi GetProcessMemoryInfo 需要的结构（只用到 WorkingSetSize 为止，
/// cb 用完整 sizeOf 保证调用约定兼容）。
final class ProcessMemoryCounters extends Struct {
  @Uint32()
  external int cb;
  @Uint32()
  external int pageFaultCount;
  @IntPtr()
  external int peakWorkingSetSize;
  @IntPtr()
  external int workingSetSize;
  @IntPtr()
  external int quotaPeakPagedPoolUsage;
  @IntPtr()
  external int quotaPagedPoolUsage;
  @IntPtr()
  external int quotaPeakNonPagedPoolUsage;
  @IntPtr()
  external int quotaNonPagedPoolUsage;
  @IntPtr()
  external int pagefileUsage;
  @IntPtr()
  external int peakPagefileUsage;
}
