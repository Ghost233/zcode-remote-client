import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// 更新源配置：GitHub Releases。
const kRepoOwner = 'Ghost233';
const kRepoName = 'zcode-remote-client';

/// 构建期注入的提交短哈希（CI 用 --dart-define=BUILD_HASH 写入；
/// 本地 flutter run 未注入时为空字符串）。
const String kBuildHash = String.fromEnvironment('BUILD_HASH');

/// 用户主动取消下载（已下载分段保留，下次断点续传）。
class UpdateDownloadCancelled implements Exception {
  const UpdateDownloadCancelled();
}

class ReleaseAsset {
  const ReleaseAsset({
    required this.name,
    required this.url,
    required this.size,
  });

  final String name;
  final String url;
  final int size;
}

class AppRelease {
  const AppRelease({
    required this.tagName,
    required this.htmlUrl,
    required this.notes,
    required this.assets,
  });

  final String tagName;
  final String htmlUrl;
  final String notes;
  final List<ReleaseAsset> assets;

  /// tag "v1.2.3" → "1.2.3"
  String get version =>
      tagName.startsWith('v') ? tagName.substring(1) : tagName;

  /// 按设备支持的 ABI 优先级挑选 APK（发布页可能同时挂多个架构的包）。
  /// [abis] 形如 ['arm64-v8a', 'armeabi-v7a']（Android 取 supportedAbis）。
  /// 都匹配不到时退回第一个 .apk。
  ReleaseAsset? androidApkFor(List<String> abis) {
    final apks = assets.where((a) => a.name.endsWith('.apk')).toList();
    if (apks.isEmpty) return null;
    for (final abi in abis) {
      for (final apk in apks) {
        if (apk.name.contains(abi)) return apk;
      }
    }
    return apks.first;
  }

  /// 兼容旧调用：不指定 ABI 时取第一个 APK。
  ReleaseAsset? get androidApk => androidApkFor(const []);
}

/// 探测结果：总大小 / ETag / 服务器是否支持 Range 分段。
class _ProbeResult {
  const _ProbeResult(this.total, this.etag, this.ranges);

  final int total;
  final String etag;
  final bool ranges;
}

/// 各分段共享的会话状态：一段失败/取消/远端变更时通知其他段尽快收手。
class _SegmentSession {
  bool cancelled = false;
  bool failed = false;
  bool remoteChanged = false;
}

/// 分段被中止（不是本段的可重试错误，由会话状态说明原因）。
class _SegmentAborted implements Exception {
  const _SegmentAborted();
}

class UpdateChecker {
  /// 拉取最新 release；网络失败/限流时返回 null（调用方按需提示）。
  static Future<AppRelease?> fetchLatest() async {
    try {
      final res = await http
          .get(
            Uri.parse(
              'https://api.github.com/repos/$kRepoOwner/$kRepoName/releases/latest',
            ),
            headers: {'Accept': 'application/vnd.github+json'},
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return null;
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      return AppRelease(
        tagName: json['tag_name'] as String,
        htmlUrl: json['html_url'] as String,
        notes: (json['body'] as String?) ?? '',
        assets: ((json['assets'] as List?) ?? const [])
            .map(
              (e) => ReleaseAsset(
                name: e['name'] as String,
                url: e['browser_download_url'] as String,
                size: e['size'] as int,
              ),
            )
            .toList(),
      );
    } catch (_) {
      return null;
    }
  }

  /// 语义化版本比较：latest > current 返回 true。
  /// 容忍 "v" 前缀、"+build" 后缀和缺失的位。
  static bool isNewer(String latest, String current) {
    List<int> parts(String v) {
      var s = v.trim();
      if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
      s = s.split('+').first;
      return s
          .split('.')
          .map(
            (e) =>
                int.tryParse(RegExp(r'\d+').firstMatch(e)?.group(0) ?? '') ?? 0,
          )
          .toList();
    }

    final l = parts(latest);
    final c = parts(current);
    for (var i = 0; i < 3; i++) {
      final li = i < l.length ? l[i] : 0;
      final ci = i < c.length ? c[i] : 0;
      if (li != ci) return li > ci;
    }
    return false;
  }

  // ---------- 分段下载（迅雷/FlashGet 式多连接并行） ----------

  /// 并发连接数。4 条对 GitHub CDN 友好，移动网络下也不至于
  /// 触发无线电台争用反而降速。
  static const int _maxConnections = 4;

  /// 文件小于该值的 2 倍不分段（分段开销大于收益）。
  static const int _minSegmentBytes = 2 * 1024 * 1024;

  static const int _maxSegmentRetries = 30;
  static const Duration _connectTimeout = Duration(seconds: 20);
  static const Duration _stallTimeout = Duration(seconds: 20);

  /// 下载匹配设备 ABI 的 APK，返回文件路径；永久性失败返回 null。
  ///
  /// 弱网加固：
  /// - 分段并行：探测大小/ETag/Range 支持后均匀分段，多连接同时下载，
  ///   单条连接被限速或卡死不影响其他段；
  /// - 断点续传：每段独立落盘（`<名>.partN`），段内进度即文件长度，
  ///   重启/重装后继续，meta 记录 ETag + 分段方案（不符则整体重来，
  ///   防止远端文件变更后拼出损坏包）；
  /// - 自动重试：连接失败/读超时（20s 无数据）逐段自动续传重试，
  ///   每段最多 30 次；
  /// - 完整性：每段长度校验 + 拼装后总大小校验；
  /// - [shouldCancel] 返回 true 时抛 [UpdateDownloadCancelled] 中止，
  ///   已下载分段保留。
  static Future<String?> downloadAndroidApk(
    AppRelease release,
    void Function(int received, int total) onProgress, {
    List<String> abis = const [],
    bool Function()? shouldCancel,
    void Function(int attempt)? onRetry,
  }) async {
    final asset = release.androidApkFor(abis);
    if (asset == null) return null;

    // 应用支持目录而非临时缓存：跨次启动仍可续传。
    final dir = await getApplicationSupportDirectory();
    final downloadDir = Directory('${dir.path}/downloads');
    await downloadDir.create(recursive: true);
    final target = File('${downloadDir.path}/${asset.name}');
    final metaFile = File('${downloadDir.path}/${asset.name}.meta');

    // 最多两轮：远端文件变更（ETag 不符）时清空断点整体重来一次。
    for (var round = 0; round < 2; round++) {
      final probe = await _probe(asset);
      if (probe == null) return null;

      // 分段方案（确定性计算并记入 meta，断点复用前会校验一致）。
      final segCount = (probe.ranges && probe.total >= _minSegmentBytes * 2)
          ? min(_maxConnections, probe.total ~/ _minSegmentBytes)
          : 1;
      final segLen = probe.total ~/ segCount;
      final segments = <List<int>>[
        for (var i = 0; i < segCount; i++)
          [i * segLen, i == segCount - 1 ? probe.total - 1 : (i + 1) * segLen - 1],
      ];

      // 断点校验：ETag、总大小、分段方案全部一致才复用已下载分段。
      var reuse = false;
      if (await metaFile.exists()) {
        try {
          final m = jsonDecode(await metaFile.readAsString());
          if ((m as Map)['v'] == 2 &&
              m['etag'] == probe.etag &&
              m['total'] == probe.total &&
              _samePlan(m['segs'], segments)) {
            reuse = true;
          }
        } catch (_) {}
      }
      if (!reuse) {
        await _cleanParts(downloadDir, asset.name);
        await metaFile.writeAsString(
          jsonEncode({'v': 2, 'etag': probe.etag, 'total': probe.total, 'segs': segments}),
        );
      }

      // 断点续传时先把已有进度算进总进度条。
      var received = 0;
      if (reuse) {
        for (var i = 0; i < segCount; i++) {
          final f = File('${downloadDir.path}/${asset.name}.part$i');
          if (await f.exists()) {
            received += min(await f.length(), segments[i][1] - segments[i][0] + 1);
          }
        }
        onProgress(received, probe.total);
      }

      final session = _SegmentSession();
      try {
        await Future.wait([
          for (var i = 0; i < segCount; i++)
            _downloadSegment(
              asset,
              File('${downloadDir.path}/${asset.name}.part$i'),
              segments[i][0],
              segments[i][1],
              probe.etag,
              probe.total,
              (delta) {
                received += delta;
                onProgress(received, probe.total);
              },
              shouldCancel,
              onRetry,
              session,
            ),
        ]);
      } catch (_) {
        if (session.remoteChanged && round == 0) continue;
        if (session.cancelled) throw const UpdateDownloadCancelled();
        return null; // 有分段重试耗尽或探测到的永久性失败
      }
      if (session.cancelled) throw const UpdateDownloadCancelled();

      // 分段完整性校验 → 顺序拼装 → 总大小校验 → 清理。
      var ok = true;
      for (var i = 0; i < segCount && ok; i++) {
        final f = File('${downloadDir.path}/${asset.name}.part$i');
        final expect = segments[i][1] - segments[i][0] + 1;
        ok = await f.exists() && await f.length() == expect;
      }
      if (!ok) {
        if (round == 0) {
          await _cleanParts(downloadDir, asset.name);
          continue;
        }
        return null;
      }
      try {
        if (await target.exists()) await target.delete();
      } catch (_) {}
      final sink = target.openWrite();
      try {
        for (var i = 0; i < segCount; i++) {
          await sink.addStream(
            File('${downloadDir.path}/${asset.name}.part$i').openRead(),
          );
        }
      } catch (_) {
        await sink.close();
        return null;
      }
      await sink.close();
      if (await target.length() != probe.total) return null;
      await _cleanParts(downloadDir, asset.name);
      try {
        await metaFile.delete();
      } catch (_) {}
      return target.path;
    }
    return null;
  }

  /// 探测下载源：Range 0-0 请求拿总大小（Content-Range）与 ETag。
  /// 服务器忽略 Range（回 200）时回退为单连接整文件下载。
  static Future<_ProbeResult?> _probe(ReleaseAsset asset) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final client = http.Client();
      try {
        final req = http.Request('GET', Uri.parse(asset.url))
          ..headers['Range'] = 'bytes=0-0';
        final res = await client.send(req).timeout(_connectTimeout);
        await res.stream.drain<void>();
        if (res.statusCode == 206) {
          // Content-Range: bytes 0-0/12345
          final m = RegExp(r'/(\d+)\s*$').firstMatch(
            res.headers['content-range'] ?? '',
          );
          final total = m != null ? int.tryParse(m.group(1)!) : null;
          if (total != null && total > 0) {
            return _ProbeResult(total, res.headers['etag'] ?? '', true);
          }
          // 解析不出大小：用 release API 给的 size，退化为单连接。
          return _ProbeResult(asset.size, res.headers['etag'] ?? '', false);
        }
        if (res.statusCode == 200) {
          // 不支持 Range：单连接整文件。
          final total = res.contentLength ?? asset.size;
          return _ProbeResult(total, res.headers['etag'] ?? '', false);
        }
        return null; // 404/403 等永久性失败
      } catch (_) {
        // 网络抖动：重试探测
      } finally {
        client.close();
      }
    }
    return null;
  }

  /// 下载单个分段到独立 part 文件（段内断点续传 + 自动重试 + 卡死超时）。
  static Future<void> _downloadSegment(
    ReleaseAsset asset,
    File partFile,
    int start,
    int end,
    String etag,
    int total,
    void Function(int delta) onDelta,
    bool Function()? shouldCancel,
    void Function(int attempt)? onRetry,
    _SegmentSession session,
  ) async {
    final segLen = end - start + 1;
    for (var attempt = 1; attempt <= _maxSegmentRetries; attempt++) {
      if (shouldCancel != null && shouldCancel()) {
        session.cancelled = true;
        throw const UpdateDownloadCancelled();
      }
      if (session.failed || session.remoteChanged) {
        throw const _SegmentAborted();
      }

      var done = 0;
      if (await partFile.exists()) {
        done = await partFile.length();
        if (done > segLen) {
          await partFile.delete(); // 本地异常：作废重下
          done = 0;
        } else if (done == segLen) {
          return; // 本段已完成（断点复用）
        }
      }

      final client = http.Client();
      try {
        final req = http.Request('GET', Uri.parse(asset.url))
          ..headers['Range'] = 'bytes=${start + done}-$end';
        if (done > 0 && etag.isNotEmpty) req.headers['If-Range'] = etag;
        final res = await client.send(req).timeout(_connectTimeout);
        if (res.statusCode == 200 && !(start == 0 && end == total - 1 && done == 0)) {
          // 只在"整文件请求"时 200 才合法（HTTP 允许服务器对全区间回 200）；
          // 续传或多段请求回 200 = 远端文件已变更/服务器不认 Range。
          session.remoteChanged = true;
          throw const _SegmentAborted();
        }
        if (res.statusCode != 206 && res.statusCode != 200) {
          session.failed = true; // 404/403：重试无意义
          throw const _SegmentAborted();
        }

        final sink = partFile.openWrite(
          mode: done > 0 ? FileMode.append : FileMode.write,
        );
        try {
          // timeout：一段时间收不到数据视为连接卡死，走段内重试。
          await for (final chunk in res.stream.timeout(_stallTimeout)) {
            if (shouldCancel != null && shouldCancel()) {
              session.cancelled = true;
              throw const UpdateDownloadCancelled();
            }
            if (session.failed || session.remoteChanged) {
              throw const _SegmentAborted();
            }
            sink.add(chunk);
            done += chunk.length;
            onDelta(chunk.length);
          }
        } finally {
          try {
            await sink.flush();
          } catch (_) {}
          await sink.close();
        }
        if (done == segLen) return;
        throw StateError('分段下载不完整($done/$segLen)');
      } on UpdateDownloadCancelled {
        rethrow;
      } on _SegmentAborted {
        rethrow;
      } catch (_) {
        if (attempt >= _maxSegmentRetries) {
          session.failed = true;
          throw const _SegmentAborted();
        }
        onRetry?.call(attempt);
        // 退避重试，封顶 8 秒。
        final delay = attempt < 8 ? attempt : 8;
        await Future<void>.delayed(Duration(seconds: delay));
      } finally {
        client.close();
      }
    }
    session.failed = true;
    throw const _SegmentAborted();
  }

  static bool _samePlan(dynamic segs, List<List<int>> plan) {
    if (segs is! List || segs.length != plan.length) return false;
    for (var i = 0; i < plan.length; i++) {
      final s = segs[i];
      if (s is! List || s.length != 2) return false;
      if (s[0] != plan[i][0] || s[1] != plan[i][1]) return false;
    }
    return true;
  }

  /// 清掉该资产的所有分段 part 文件（保留 meta 由调用方处理）。
  static Future<void> _cleanParts(Directory dir, String name) async {
    try {
      for (final entity in dir.listSync()) {
        if (entity is File &&
            entity.path.contains('/') &&
            entity.uri.pathSegments.last.startsWith('$name.part')) {
          await entity.delete();
        }
      }
    } catch (_) {}
  }
}
