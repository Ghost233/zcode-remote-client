import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// 更新源配置：GitHub Releases。
const kRepoOwner = 'Ghost233';
const kRepoName = 'zcode-remote-client';

/// 构建期注入的提交短哈希（CI 用 --dart-define=BUILD_HASH 写入；
/// 本地 flutter run 未注入时为空字符串）。
const String kBuildHash = String.fromEnvironment('BUILD_HASH');

/// 用户主动取消下载（已下载部分保留，下次断点续传）。
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

  /// 下载匹配设备 ABI 的 APK，返回文件路径；永久性失败返回 null。
  ///
  /// 弱网加固：
  /// - 断点续传：部分文件存应用支持目录（不会被系统清理），HTTP Range 续传，
  ///   If-Range 带 ETag 校验（远端文件变了自动回退全量重下，防串包）；
  /// - 自动重试：连接失败/读超时（20s 无数据）自动断点续传重试，最多 30 次；
  /// - 完整性：下完校验总字节数；
  /// - [shouldCancel] 返回 true 时抛 [UpdateDownloadCancelled] 中止，
  ///   已下载部分保留。
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
    final part = File('${downloadDir.path}/${asset.name}.part');
    final target = File('${downloadDir.path}/${asset.name}');
    final metaFile = File('${downloadDir.path}/${asset.name}.meta');

    var etag = '';
    var total = 0;
    if (await metaFile.exists()) {
      try {
        final m = jsonDecode(await metaFile.readAsString());
        etag = (m as Map)['etag'] as String? ?? '';
        total = (m['total'] as int?) ?? 0;
      } catch (_) {
        try {
          await metaFile.delete();
        } catch (_) {}
      }
    }

    const maxAttempts = 30;
    const connectTimeout = Duration(seconds: 20);
    const stallTimeout = Duration(seconds: 20);

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (shouldCancel != null && shouldCancel()) {
        throw const UpdateDownloadCancelled();
      }
      try {
        var start = 0;
        if (await part.exists()) start = await part.length();
        if (total > 0 && (start <= 0 || start > total)) {
          // 没有可靠的续传元信息或本地比远端还大：作废重下。
          try {
            await part.delete();
          } catch (_) {}
          start = 0;
          etag = '';
          total = 0;
        }

        final client = http.Client();
        try {
          final req = http.Request('GET', Uri.parse(asset.url));
          if (start > 0) {
            req.headers['Range'] = 'bytes=$start-';
            if (etag.isNotEmpty) req.headers['If-Range'] = etag;
          }
          final res = await client.send(req).timeout(connectTimeout);
          if (res.statusCode != 200 && res.statusCode != 206) {
            // 404/403 等永久性失败，重试没有意义。
            return null;
          }
          final resuming = res.statusCode == 206 && start > 0;
          if (!resuming) {
            start = 0;
            total = res.contentLength ?? asset.size;
            etag = res.headers['etag'] ?? '';
          } else {
            total = start + (res.contentLength ?? (total - start));
          }
          if (total <= 0) total = asset.size;
          await metaFile.writeAsString(
            jsonEncode({'etag': etag, 'total': total}),
          );

          var received = start;
          final sink = part.openWrite(
            mode: resuming ? FileMode.append : FileMode.write,
          );
          try {
            // timeout：一段时间收不到数据视为连接卡死，抛错走重试。
            await for (final chunk in res.stream.timeout(stallTimeout)) {
              if (shouldCancel != null && shouldCancel()) {
                throw const UpdateDownloadCancelled();
              }
              sink.add(chunk);
              received += chunk.length;
              onProgress(received, total);
            }
          } finally {
            try {
              await sink.flush();
            } catch (_) {}
            await sink.close();
          }

          if (received < total) {
            throw StateError('下载不完整($received/$total)');
          }
          try {
            if (await target.exists()) await target.delete();
          } catch (_) {}
          await part.rename(target.path);
          try {
            await metaFile.delete();
          } catch (_) {}
          return target.path;
        } finally {
          client.close();
        }
      } on UpdateDownloadCancelled {
        rethrow;
      } catch (_) {
        if (attempt >= maxAttempts) return null;
        onRetry?.call(attempt);
        // 退避重试，封顶 8 秒。
        final delay = attempt < 8 ? attempt : 8;
        await Future<void>.delayed(Duration(seconds: delay));
      }
    }
    return null;
  }
}
