import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// 更新源配置：GitHub Releases。
const kRepoOwner = 'Ghost233';
const kRepoName = 'zcode-remote-client';

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

  ReleaseAsset? get androidApk {
    for (final a in assets) {
      if (a.name.endsWith('.apk')) return a;
    }
    return null;
  }
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

  /// 下载 release 里的 APK 到临时目录，返回文件路径；失败返回 null。
  static Future<String?> downloadAndroidApk(
    AppRelease release,
    void Function(int received, int total) onProgress,
  ) async {
    final asset = release.androidApk;
    if (asset == null) return null;
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/${asset.name}');
    final client = http.Client();
    try {
      final res = await client.send(http.Request('GET', Uri.parse(asset.url)));
      if (res.statusCode != 200) return null;
      final total = res.contentLength ?? asset.size;
      var received = 0;
      final sink = file.openWrite();
      await for (final chunk in res.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress(received, total);
      }
      await sink.flush();
      await sink.close();
      return file.path;
    } catch (_) {
      try {
        await file.delete();
      } catch (_) {}
      return null;
    } finally {
      client.close();
    }
  }
}
